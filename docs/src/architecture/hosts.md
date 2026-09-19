# Hosts and boot

## Three configurations, two machines

`flake.nix` builds three systems from two builders:

| Configuration                        | Builder    | Root disk           | Used by                                                              |
| ------------------------------------ | ---------- | ------------------- | -------------------------------------------------------------------- |
| `nixosConfigurations.vps`            | `mkVps`    | `/dev/vda` (virtio) | the local QEMU test VM (`nix run .#default`)                         |
| `nixosConfigurations.vps-hetzner`    | `mkVps`    | `/dev/sda`          | what tofu/nixos-anywhere installs, and what `deploy .#vps` activates |
| `nixosConfigurations.runner-hetzner` | `mkRunner` | `/dev/sda`          | the CI runner box                                                    |

The first two differ in exactly one attribute — the disko device — and share
every module, every container, every secret. `vps-hetzner` is the real system;
`vps` exists so the same closure can be booted and tested locally.

`runner-hetzner` is a second `nixosSystem` in the same flake rather than a
second flake, because it shares boot, hardware, nix, security and the disk
layout verbatim. What it deliberately does not share is listed in
`runner/configuration.nix`.

**Note the argument that is absent.** `mkVps` passes
`sops-nix.nixosModules.sops`; `mkRunner` does not. The runner holds no age key
and can decrypt nothing in `secrets.yaml`, so the module would only add a unit
that fails at boot. This is enforced, not just intended — the flake carries a
check named `runner-has-no-secrets`, and it is a `nix build` rather than an
evaluation, because a check that is only evaluated never runs its builder and
its failure branch is inert.

Inputs are minimal and all `follows` nixpkgs (`nixos-26.05`): `disko` (disk
layout), `sops-nix` (secrets), `deploy-rs` (the deploy circuit breaker).

## Boot and disk

The disk is GPT with three partitions (`disk-config.nix`): a 1 M `EF02`
BIOS-boot partition, a 1 G `EF00` ESP mounted at `/boot`, and ext4 root filling
the rest. Both machines use the same layout; the runner's 80 GB is picked up
without a line changing, because the root partition is `size = "100%"`.

Two hardware facts drive this and are not preferences:

- **GRUB, configured for BIOS _and_ UEFI** (`boot.nix`). Hetzner Cloud boots
  these VMs in **legacy BIOS mode** — the running machine has no
  `/sys/firmware/efi`. systemd-boot is EFI-only and would install cleanly, then
  leave an unbootable box on first reboot. GRUB embeds its core image in the
  `EF02` partition (BIOS chain-loads it) _and_ writes `/EFI/BOOT/BOOTX64.EFI`
  (the fallback UEFI firmware looks for with no NVRAM entry), so the same
  closure boots either way. `canTouchEfiVariables = false`, because there is no
  efivarfs in BIOS mode.
- **virtio kernel modules in the initrd** (`hardware.nix`). NixOS's default
  `availableKernelModules` targets bare metal and contains _no_ virtio drivers.
  Hetzner presents the disk over virtio, so without these the initrd cannot see
  `/dev/sda`, cannot mount root, and drops to an emergency shell — while the
  provider still reports the server `running`. The nixos-anywhere `--vm-test`
  cannot catch this; the test harness injects its own virtio modules.

The ESP is 1 G, not 512 M, because it _is_ `/boot` and holds a kernel + initrd
per generation. It cannot be grown without a reinstall, and filling it breaks
the next deploy rather than the current boot.

## The machines themselves

```text
hu-tao          163906050  cx43  fsn1  167.233.24.58   mail, git, everything
                                       2a01:4f8:c015:b138::/64
forgejo-runner  166488672  cx33  nbg1  46.225.61.172   CI only
```

Both carry `delete_protection` and `rebuild_protection`, with `user_data` in
`lifecycle.ignore_changes`. **They are rebuilt in place, never recreated** — CX
instance types are limited availability, and a `destroy`/`create` cycle can
find nothing to create.

The runners are a fleet rather than a box: `for_each` over `runner_names` in
`tofu/`, with the address and identity maps keyed by **server name** rather
than by index. An address on its own says nothing about which box it belongs
to, and a bare list invites being correlated by index with some other list —
which stays silently wrong when an entry is removed from the middle.

The VPS's public IPv4 is its own resource with delete protection, deliberately
separate from the server, so an IP handover carries mail reputation to a new
box with no DNS change. See [Migration off Ubuntu](../history/migration.md).
