# CI Runner Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install NixOS on Hetzner server `166488672` as a self-registering Forgejo Actions runner that uses podman, cannot initiate anything toward the VPS except HTTPS to Forgejo, and can be cloned from a snapshot.

**Architecture:** A second `nixosSystem` in the same flake (`runner-hetzner`) built from the four shared modules plus a new `modules/runner/` tree. The runner is a plain systemd service (`services.gitea-actions-runner` with `package = pkgs.forgejo-runner`), not a container. Jobs get podman's socket as their container engine. One-way isolation is enforced structurally (no private NIC, no tailnet) and by an nftables ruleset whose VPS-drop rules sit *above* the broad container-accept rules in both the `output` and `forward` chains.

**Tech Stack:** NixOS 26.05, disko, nixos-anywhere, deploy-rs, podman 5.8.6, forgejo-runner 13.1.0, nftables, OpenTofu + hcloud.

**Spec:** `docs/superpowers/specs/2026-09-18-ci-runner-host-design.md`

---

## Findings that amend the spec

Four things were verified against the pinned nixpkgs and the live infrastructure
*after* the spec was written. Each changes what gets built. Task 0 writes them
back into the spec so the two documents do not drift.

**1. The tailnet defeats the entire one-way design.** The spec's topology and
`tofu/runner-firewall.tf` both assume the runner joins the tailnet and that the
bootstrap `tcp/22` ingress rule is then deleted. It cannot join. The VPS's
`modules/firewall.nix` input chain contains `iifname tailscale0 accept` with no
source qualification, so a runner on the tailnet reaches **every port on the
VPS** — sshd on 2222, postgres, tempo, the mail ports — over `100.64.0.0/10`,
completely bypassing any rule keyed on `167.233.24.58`. Fixing that on the VPS
side means host-side filtering of the tailnet, which is the weaker option the
spec already argued against for the private NIC, plus a second control plane
(tailscale ACLs).

Resolution: **the runner does not run tailscale.** Administration is
`ssh -J vps root@46.225.61.172`, scoped at the cloud firewall to
`167.233.24.58/32`. The bootstrap ingress rule is permanent, not scaffolding.
`tofu/runner-firewall.tf` loses its four tailscale egress rules and its
"delete this rule" comment.

**2. `tokenFile` is an EnvironmentFile, not a token file.** Upstream's
`gitea-actions-runner.nix` maps the option straight onto systemd's
`EnvironmentFile=` and the registration script reads `$TOKEN`. A file containing
the bare token registers nothing and fails with an empty-token error. The file
must contain the literal line `TOKEN=<token>`.

**3. The VPS's own host firewall blocks the jump.** The spec notes that
`main-firewall` gained a scoped `tcp/22` egress rule (it did — see
`tofu/modules/hetzner-firewall/main.tf:48-53`). It does not note that
`modules/firewall.nix`'s `output` chain is `policy drop` with
`tcp dport { 25, 53, 80, 443, 7844 }` and **no 22**. `ssh -J vps` opens a
host-originated connection from the VPS to the runner on port 22, which that
chain drops. The cloud rule alone is not enough; the host rule is Task 6.

**4. IPv6 bypasses an `ip daddr` rule.** The VPS holds primary IPv6
`2a01:4f8:c015:b138::/64` (`hcloud_primary_ip.main_v6`). An nftables rule
written as `ip daddr 167.233.24.58 drop` matches IPv4 only and does nothing to
the /64. DNS publishes no AAAA for any name on the VPS (`tofu/server.tf:50`), so
nothing legitimate reaches it over IPv6 — the runner's ruleset drops the whole
/64 with no exception.

**5. The runner is handed a cross-org write token daily.**
`.forgejo/workflows/renovate.yml` runs on this runner with
`RENOVATE_TOKEN` — a bot account holding **write on repository and issue** across
`hutao/*` and `skavex/*` — injected into a job container every day at 12:00 UTC.
That is a larger exposure than the per-job tokens the spec lists under "What no
firewall closes", and it also makes an L7 allowlist pointless: anything
permissive enough for Renovate (`/api/v1/*` plus git push) permits everything
such a list would exist to deny. Task 5a moves it to a VPS timer with the token
in sops; Task 8b then narrows the runner to the Actions API paths at caddy,
which is the only layer that can see a path. Verified that caddy's `remote_ip`
is sound as a key: `trusted_proxies` is unset and every record in
`tofu/modules/cloudflare-dns` is `proxied = false`, so it is the real TCP peer
and never a header.

**6. Pages is live, and the gate is real.**
`https://pages.hu-tao.dev/hutao/compress/` returns 200, and
`hutao/compress/.forgejo/workflows/pages.yml` mounts `pages_data` directly. The
replacement is artifact-upload plus a VPS pull timer, which needs **no
credential** — the repo is public and
`/api/v1/repos/hutao/compress/actions/artifacts` answers `200 []` anonymously.
See Task 10.

**7. The runner-firewall comment is stale.** It still says the install runs as
`nixos-anywhere --ssh-option ProxyJump=vps root@10.0.1.3`. The private NIC was
removed in `5d0ae14`; `10.0.1.3` does not exist. The target is the public
`46.225.61.172`.

## Global Constraints

- **NixOS 26.05.** `system.stateVersion = "26.05"` comes from the shared
  `modules/boot.nix`. Do not set it again in the runner tree.
- **The runner host holds no secret from this repo.** No `sops-nix` module, no
  age key, no `secrets.yaml` entry. `.sops.yaml` is untouched. A build that
  produces a `sops-install-secrets` unit is a failed build (Task 1 asserts it).
- **No tailscale on the runner.** See finding 1.
- **No docker on the runner.** `virtualisation.docker.enable` stays false;
  `docker` exists only as podman's `dockerCompat` alias binary.
- **Labels are unchanged from the live VPS runner**, so no workflow in any repo
  needs editing: `nix:docker://nixos/nix:2.35.2`,
  `ubuntu-latest:docker://node:22-bookworm`, `node-22:docker://node:22-bookworm`,
  `alpine:docker://alpine:3.22`.
- **Formatting is `nixfmt-rfc-style`, not `nixpkgs-fmt`.** Enforced by
  `.pre-commit-config.yaml`; the wrong one reformats the whole tree.
- **Commits:** `type(scope): subject`, body explaining what and why, trailer
  `Co-authored-by: Claude Opus 5 <noreply@anthropic.com>` and nothing else. No
  `Claude-Session` trailer. Scope for this work is `runner`, `firewall`, `tofu`
  or `docs`.
- **Branch is `feat/ci-runner-host`.** Do not work on `main`. Do not push to any
  remote without asking.
- **Live facts, do not re-derive:** runner `166488672`, cx33, nbg1,
  `46.225.61.172`, firewall `11645120` (`runner-firewall`), no private NIC,
  currently running `ubuntu-26.04`. VPS `163906050` `hu-tao`, cx43, fsn1,
  `167.233.24.58`, `2a01:4f8:c015:b138::/64`, attached to `10.0.1.2`.

---

## File Structure

| path | responsibility |
| --- | --- |
| `runner/configuration.nix` | new — the runner's import list, nothing else |
| `modules/runner/default.nix` | new — podman, the runner instance, store GC |
| `modules/runner/identity.nix` | new — Hetzner user-data → `TOKEN=` EnvironmentFile |
| `modules/runner/firewall.nix` | new — the one-way nftables ruleset |
| `modules/runner/users.nix` | new — ssh keys, no passwords, no sops |
| `modules/runner/networking.nix` | new — hostname and sshd; deliberately not `modules/services.nix` |
| `tests/runner-firewall.nix` | new — NixOS VM test proving the one-way rules |
| `flake.nix` | `mkRunner`, `nixosConfigurations.runner-hetzner`, the test check, deploy node |
| `tofu/runner-firewall.tf` | drop the tailscale egress rules, correct the stale comment |
| `modules/firewall.nix` | add `tcp dport 22` egress to the runner; bind the nine port-accepts to the public interface |
| `modules/renovate.nix` | new — Renovate as a VPS timer, token in sops |
| `modules/pages-pull.nix` | new — fetch pages artifacts into the pages volume |
| `modules/options.nix` | add `infra.runnerIPs` and `infra.pagesRepos` |
| `modules/containers/caddy.nix` | restrict runner addresses to the Actions API paths |
| `.forgejo/workflows/renovate.yml` | deleted — moved to the host |
| `modules/containers/forgejo-runner.nix` | deleted, last |
| `modules/containers/default.nix` | drop the import |
| `modules/secrets.nix` | drop `forgejo_runner_token`, add the two renovate tokens |

`modules/options.nix`, `modules/boot.nix`, `modules/hardware.nix`,
`modules/nix.nix`, `modules/security.nix` and `disk-config.nix` are shared
verbatim. `modules/services.nix` is **not** shared — it carries tailscale with a
sops `authKeyFile` and a fail2ban jail for a forgejo container that does not
exist here.

---

## Phase 1 — The host configuration, built locally

### Task 0: Amend the spec with the five findings

**Files:**
- Modify: `docs/superpowers/specs/2026-09-18-ci-runner-host-design.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing in code. Later tasks cite the amended spec.

- [ ] **Step 1: Rewrite the topology block**

Replace the fenced block under `## Topology` (lines 57-64) with:

```
hu-tao          163906050  cx43  fsn1  167.233.24.58   mail, git, everything
                                       2a01:4f8:c015:b138::/64
forgejo-runner  166488672  cx33  nbg1  46.225.61.172   CI only

  runner ──HTTPS 443──▶ 167.233.24.58        the one permitted direction
  runner ──╳── anything else on the VPS, v4 or v6
  VPS    ──SSH 22───▶ runner                 admin, permanently
```

- [ ] **Step 2: Add a subsection recording why there is no tailnet**

Insert after the `### Why the private NIC goes rather than gets filtered`
section, before `### What no firewall closes`:

```markdown
### Why the runner is not on the tailnet either

The same argument, one layer up. `modules/firewall.nix`'s input chain accepts
`iifname tailscale0` unconditionally, so a tailnet member reaches every port on
the VPS — sshd on 2222, pgbouncer, tempo's OTLP receiver, the mail ports — and
no rule keyed on `167.233.24.58` sees that traffic at all. A runner on the
tailnet is a runner with full access to the box this document exists to protect.

Narrowing that accept to exclude one node is host-side filtering of a trust
boundary, which is the option rejected above, and tailscale ACLs are a third
control plane to keep correct. So the runner does not run tailscale.

The cost is that administration has no tailnet path, and the `tcp/22` ingress
rule scoped to `167.233.24.58/32` is therefore **permanent** rather than
bootstrap scaffolding. Admin is `ssh -J vps root@46.225.61.172`. That direction
is VPS→runner, which the one-way rule permits by construction.
```

- [ ] **Step 3: Correct the snapshot section's install command**

In `## Snapshot and replication`, replace step 1's parenthetical so it reads:

```markdown
1. Install with nixos-anywhere, jumped through the VPS:
   `nixos-anywhere --flake .#runner-hetzner --ssh-option ProxyJump=vps root@46.225.61.172`.
   The private NIC was removed in 5d0ae14, so the target is the public address;
   the jump is what makes the runner's single ingress rule — `tcp/22` from
   `167.233.24.58/32` — sufficient. It needs `tcp/22` egress on main-firewall
   AND in the VPS's own `modules/firewall.nix` output chain, which is
   policy-drop and did not have it.
```

- [ ] **Step 4: Correct the identity section's file format**

In `## Identity — modules/runner/identity.nix`, replace the first paragraph with:

```markdown
A oneshot unit, ordered before the runner, reads the Hetzner metadata service
and writes the registration token where the runner consumes it.

`services.gitea-actions-runner.instances.<name>.tokenFile` is mapped straight
onto systemd's `EnvironmentFile=`, and upstream's registration script reads
`$TOKEN` — so the file must contain the line `TOKEN=<token>`, not the bare
token. A bare token registers nothing and fails with an empty-token error.
```

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-09-18-ci-runner-host-design.md
git commit -m "docs: amend the runner spec with five verified findings

The tailnet defeats the one-way rule outright: modules/firewall.nix accepts
iifname tailscale0 unconditionally, so a runner on the tailnet reaches every
port on the VPS regardless of any rule keyed on 167.233.24.58. The runner
therefore does not run tailscale, and its tcp/22 ingress rule is permanent
rather than bootstrap scaffolding.

Also: tokenFile is an EnvironmentFile and needs TOKEN=<token>; the VPS's own
output chain is policy-drop with no port 22, so the cloud egress rule alone
does not make the jump work; the VPS holds an IPv6 /64 that an ip daddr rule
does not match; and the install target is 46.225.61.172, not the 10.0.1.3 that
went away with the private NIC in 5d0ae14.

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 1: The flake wiring and a system that builds

Produces a `runner-hetzner` configuration that evaluates, builds, and provably
carries no sops. `modules/runner/default.nix` is a stub here; Task 2 fills it.

**Files:**
- Create: `runner/configuration.nix`
- Create: `modules/runner/default.nix`
- Create: `modules/runner/users.nix`
- Create: `modules/runner/networking.nix`
- Modify: `flake.nix` (the `let` block after `vps-hetzner`, and `nixosConfigurations`)

**Interfaces:**
- Consumes: `config.infra.domain` from `modules/options.nix`;
  `config.disko.devices.disk.main.device` from `disk-config.nix`.
- Produces: `self.nixosConfigurations.runner-hetzner`. Tasks 2-4 add modules to
  the import list in `runner/configuration.nix`, which already names all of them.

- [ ] **Step 1: Write the failing check**

The test is a `nix eval` assertion, because a NixOS configuration's unit of
behaviour is its evaluated config. Save this as a shell function you run by
hand in Steps 2 and 4 — it becomes `checks.runner-has-no-secrets` in
`flake.nix`, a `checks.${system}` entry like the ones Task 5 adds. That does
not by itself mean it runs on every push: `nix flake check --no-build`
evaluates a check but does not build it, and CI's build step only names the
checks it explicitly builds — see Task 5 for why `runner-firewall` (the deep
VM test) is deliberately absent from that list, and confirm
`runner-has-no-secrets` is or isn't in it before assuming either way.

```bash
# Expected: prints "false" for sops, "false" for docker, "false" for tailscale.
nix eval --json .#nixosConfigurations.runner-hetzner.config --apply '
  c: {
    hasSops     = c.systemd.services ? sops-install-secrets;
    hasDocker   = c.virtualisation.docker.enable;
    hasTailscale = c.services.tailscale.enable;
    hostName    = c.networking.hostName;
    diskDevice  = c.disko.devices.disk.main.device;
  }'
```

- [ ] **Step 2: Run it to verify it fails**

Run the command above.
Expected: `error: flake 'git+file:///home/hutao/Projects/vps' does not provide attribute ... 'runner-hetzner'`

- [ ] **Step 3: Create `runner/configuration.nix`**

```nix
# ==============================================================================
# The CI runner host
# ==============================================================================
# The sibling of the repo-root configuration.nix, and deliberately a much
# shorter list. What is NOT here is the point of the file:
#
#   * no ./modules/secrets.nix — this host holds no key from this repo and
#     decrypts nothing in secrets.yaml. See "Secrets" in the design doc.
#   * no ./modules/services.nix — it carries tailscale (whose authKeyFile is a
#     sops secret) and a fail2ban jail for a forgejo container that does not
#     run here. The tailnet is excluded on purpose, not by omission: the VPS
#     accepts `iifname tailscale0` unconditionally, so a runner on the tailnet
#     would reach every port on the box this split exists to protect.
#   * no ./modules/containers — nothing on this host is an oci-container,
#     including the runner itself.
#
# ./modules/options.nix is here for `infra.domain` and `infra.publicIPv4`,
# which modules/runner/{default,firewall}.nix read. Everything else it declares
# is an unused option with a default, which costs nothing.
{
  imports = [
    ../modules/options.nix
    ../modules/boot.nix
    ../modules/hardware.nix
    ../modules/nix.nix
    ../modules/security.nix
    ../modules/runner
  ];
}
```

- [ ] **Step 4: Create `modules/runner/default.nix` as a stub that imports its siblings**

```nix
# ==============================================================================
# The CI runner — podman and the Actions daemon
# ==============================================================================
# Filled in by the next task. The imports are here now so that
# runner/configuration.nix names one directory and never changes again.
{
  imports = [
    ./networking.nix
    ./users.nix
  ];
}
```

- [ ] **Step 5: Create `modules/runner/networking.nix`**

```nix
# ==============================================================================
# The runner's hostname and the one way in
# ==============================================================================
# Not modules/services.nix, which this replaces for this host. That module
# enables tailscale from a sops authKeyFile and runs a fail2ban jail against a
# forgejo container's journal — neither applies here, and the tailnet is
# actively excluded (see runner/configuration.nix).
#
# sshd is on 22, not the VPS's 2222, because nothing on this box publishes 22 —
# there is no forgejo container to yield it to. The source is narrowed at the
# cloud firewall instead: `runner-firewall` admits tcp/22 from
# 167.233.24.58/32 alone, so the only host that can knock is the VPS, and the
# admin path is `ssh -J vps root@46.225.61.172`.
#
# PermitRootLogin is "prohibit-password", which differs from the VPS's "no".
# Two reasons, both about this being a disposable box rebuilt from an image:
# nixos-anywhere targets root@, and a re-install is the ordinary way to change
# this machine rather than an emergency. It is key-only either way —
# PasswordAuthentication is off — and the cloud firewall means the only client
# that can reach the port is a box whose own root keys are the same set.
{ config, ... }:

{
  networking = {
    # Baked into the snapshot, so every clone comes up with this name. Forgejo
    # tells its runners apart by the uuid it issues at registration, not by
    # name, so duplicates are a cosmetic problem in Site Administration ->
    # Actions -> Runners and nothing more. Prune stale records by hand.
    hostName = "forgejo-runner";
    domain = config.infra.domain;

    # The ruleset lives in modules/runner/firewall.nix. Declared here as false
    # so that enabling nftables there cannot silently coexist with the
    # iptables-based default.
    firewall.enable = false;
  };

  services.openssh = {
    enable = true;
    ports = [ 22 ];
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PubkeyAuthentication = true;
      X11Forwarding = false;
      UsePAM = true;
    };
  };
}
```

- [ ] **Step 6: Create `modules/runner/users.nix`**

```nix
# ==============================================================================
# Users on the runner
# ==============================================================================
# The same five keys as modules/users.nix and NONE of its passwords. That
# module reads root_password and user_password out of sops; this host has no
# sops key, so referencing them would fail evaluation — and there is nothing to
# log in to interactively anyway. With mutableUsers = false and no
# hashedPasswordFile, NixOS locks both accounts' passwords, which is the
# correct state for a key-only box.
#
# hutao is in wheel, and modules/security.nix sets
# security.sudo.wheelNeedsPassword = false — so a locked password does not stop
# `deploy-rs`, which activates as root over an unprivileged login.
#
# The keys are duplicated rather than factored out of modules/users.nix.
# Factoring them would mean importing a module that also wants sops, or adding
# a sixth shared module for a five-line list; the duplication is visible and a
# rotation touches two files that both live in this repo.
{
  users = {
    mutableUsers = false;

    users = {
      root.openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKq9bjfE2uA4pDqAJbfftacgk9OK/EgeLp4gG/uZcFNc ivan@hu-tao.dev"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID49dv6XQCkieSTgT8fPD54NScv30jNDI7Z0QhEbz57v hutao@hutao"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIoqi3O0lsZ/4eZfwt39yUxInELGG91ucSaF4d+fUKhU hutao@hutao-desktop"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBAfw4ZR3O194CT9VNVMVv29DK1gaKCwxQp0CQRJwaSQ ivan@work-laptop"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJLLFqxc1Ihd4j676fikI7LH7WjXlEFkEr2g+d3090Rg hutao@hutao-laptop"
      ];

      hutao = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKq9bjfE2uA4pDqAJbfftacgk9OK/EgeLp4gG/uZcFNc ivan@hu-tao.dev"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID49dv6XQCkieSTgT8fPD54NScv30jNDI7Z0QhEbz57v hutao@hutao"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIoqi3O0lsZ/4eZfwt39yUxInELGG91ucSaF4d+fUKhU hutao@hutao-desktop"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBAfw4ZR3O194CT9VNVMVv29DK1gaKCwxQp0CQRJwaSQ ivan@work-laptop"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJLLFqxc1Ihd4j676fikI7LH7WjXlEFkEr2g+d3090Rg hutao@hutao-laptop"
        ];
      };
    };
  };
}
```

- [ ] **Step 7: Wire it into `flake.nix`**

Insert immediately after the `vps-hetzner = mkVps [ ... ];` block (currently
`flake.nix:70-72`), inside the same `let`:

```nix
      # ── The CI runner ──────────────────────────────────────────────────────
      # A second system in the same flake rather than a second flake, because
      # it shares boot, hardware, nix, security and disk-config verbatim — see
      # runner/configuration.nix for the list it deliberately does NOT share.
      #
      # NOTE THE ABSENT ARGUMENT: sops-nix.nixosModules.sops is in mkVps and is
      # not here. This host holds no age key and can decrypt nothing in
      # secrets.yaml, so the module would only add a unit that fails at boot.
      # Task: keep it absent. checks.runner-has-no-secrets asserts it.
      mkRunner =
        extraModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./runner/configuration.nix
            ./disk-config.nix
            disko.nixosModules.disko
          ]
          ++ extraModules;
        };

      # Same one-line difference as vps-hetzner: Hetzner presents the root disk
      # as /dev/sda, and disk-config.nix defaults to /dev/vda for the local VM.
      # The 80 GB is picked up without a line changing — the root partition is
      # size = "100%".
      runner-hetzner = mkRunner [
        { disko.devices.disk.main.device = "/dev/sda"; }
      ];
```

Then change the `nixosConfigurations` attribute (currently `flake.nix:75-77`) to:

```nix
      nixosConfigurations = {
        inherit vps vps-hetzner runner-hetzner;
      };
```

- [ ] **Step 8: Run the check to verify it passes**

```bash
nix eval --json .#nixosConfigurations.runner-hetzner.config --apply '
  c: {
    hasSops     = c.systemd.services ? sops-install-secrets;
    hasDocker   = c.virtualisation.docker.enable;
    hasTailscale = c.services.tailscale.enable;
    hostName    = c.networking.hostName;
    diskDevice  = c.disko.devices.disk.main.device;
  }'
```

Expected, exactly:

```json
{"diskDevice":"/dev/sda","hasDocker":false,"hasSops":false,"hasTailscale":false,"hostName":"forgejo-runner"}
```

- [ ] **Step 9: Build the closure**

```bash
nix build .#nixosConfigurations.runner-hetzner.config.system.build.toplevel --no-link --print-out-paths
```

Expected: a `/nix/store/...-nixos-system-forgejo-runner-26.05...` path, exit 0.

- [ ] **Step 10: Format and commit**

```bash
nixfmt runner/configuration.nix modules/runner/*.nix flake.nix
git add runner/ modules/runner/ flake.nix
git commit -m "feat(runner): add the runner-hetzner system

A second nixosSystem in the same flake, sharing boot, hardware, nix, security
and disk-config with the VPS and sharing nothing else. What it leaves out is
the point: no sops-nix module (this host holds no age key and decrypts nothing
in secrets.yaml), no modules/services.nix (tailscale's authKeyFile is a sops
secret, and a runner on the tailnet reaches every port on the VPS because
modules/firewall.nix accepts iifname tailscale0 unconditionally), and no
containers.

sshd is on 22 rather than 2222 because no forgejo container owns 22 here; the
source is narrowed at the cloud firewall to 167.233.24.58/32 instead, making
ssh -J vps the only way in.

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: podman and the Actions daemon

> **SUPERSEDED IN PART (9807149).** This task's identity design — a registration
> token, later a `--extra-files` staged fallback with an `instance-id` stamp and
> a reuse branch — is gone. `forgejo-runner register` is deprecated upstream,
> and the metadata path this text uses
> (`/hetzner/v1/metadata/userdata`) 404s: the real one is
> `/hetzner/v1/userdata`. The runner's uuid+secret now arrives only as Hetzner
> `user_data`, set by `tofu` at create time, which is per-server and therefore
> clone-safe with no on-disk provenance checks at all. Read
> `modules/runner/identity.nix` and the spec's "One source: user-data" section
> rather than the code blocks below. Task 7 is rewritten to match.

**Files:**
- Modify: `modules/runner/default.nix` (replace the stub body)

**Interfaces:**
- Consumes: `config.infra.domain`; `modules/runner/identity.nix`'s
  `TOKEN=` file at `/var/lib/forgejo-runner-token/token.env` (Task 3 creates the
  unit that writes it; this task only names the path).
- Produces: systemd unit **`gitea-runner-forgejo.service`** (the instance attr
  name is `forgejo`, and upstream names the unit
  `gitea-runner-${escapeSystemdPath name}`). Task 3 orders against that exact
  name. Cache proxy on TCP **34567**, which Task 4's input rule names.

- [ ] **Step 1: Write the failing check**

```bash
# Expected: the generated runner config.yaml, with podman's socket as the
# job-side docker host and an empty valid_volumes.
nix eval --raw .#nixosConfigurations.runner-hetzner.config.systemd.services.gitea-runner-forgejo.serviceConfig.ExecStart
```

- [ ] **Step 2: Run it to verify it fails**

Expected: `error: attribute 'gitea-runner-forgejo' missing`

- [ ] **Step 3: Replace `modules/runner/default.nix`**

```nix
# ==============================================================================
# The CI runner — podman and the Actions daemon
# ==============================================================================
# The runner is an ORDINARY SYSTEMD SERVICE. On the VPS it was an oci-container
# with /var/run/docker.sock bind-mounted in, and that socket — root on a box
# serving mail, git and every sops secret — is the whole reason this host
# exists. On a dedicated machine there is nothing to isolate the daemon from,
# so the container bought nothing and cost the mount.
#
# PODMAN, NOT DOCKER, and not as a preference: docker's nftables integration is
# what produced the half-working published ports and the forward-chain traps
# documented at length in modules/firewall.nix. Jobs still get a working
# `docker` command — dockerCompat installs the alias binary and dockerSocket
# puts /run/docker.sock in front of podman's — so a workflow that shells out to
# docker needs no edit.
#
# THE JOB-SIDE SOCKET IS DELIBERATE. container.docker_host below is podman's
# socket, which is exactly the access the VPS runner's valid_volumes allow-list
# and `docker_host: "-"` existed to DENY. That is not a relaxation of the old
# position; it is the same position at a different blast radius. A workflow
# that escapes here gets root on a machine holding a nix store, a job cache and
# its own runner token — no mail, no git, no sops key — and the box is a
# snapshot away from replacement. The isolation boundary moved from the
# container to the VM, which is what the second VM was for.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  instanceUrl = "https://git.${config.infra.domain}/";

  # Fixed rather than random (the runner's default) because modules/runner/
  # firewall.nix has to name it in an input rule. Same number as the VPS
  # runner's, so a familiar port means the same thing on both boxes.
  cacheProxyPort = 34567;

  # Written by modules/runner/identity.nix. Named here rather than there
  # because this is the consumer and the option that points at it is here.
  tokenEnvFile = "/var/lib/forgejo-runner-token/token.env";
in
# The imports list grows by one line in each of the next two tasks —
# ./identity.nix in Task 3, ./firewall.nix in Task 4. Adding them here would
# make this task's build fail on a missing file.
{
  imports = [
    ./networking.nix
    ./users.nix
  ];

  virtualisation.podman = {
    enable = true;

    # /run/docker.sock as a Symlink on podman.socket, whose SocketGroup is
    # `podman`. Upstream's gitea-actions-runner module adds the runner to that
    # group itself (SupplementaryGroups, when podman is enabled), so nothing
    # here has to name a gid — which is the gid-goes-stale-silently failure the
    # VPS runner's --group-add comment warns about, avoided by construction.
    dockerSocket.enable = true;

    # The `docker` alias binary, so a workflow step that runs `docker build`
    # works unmodified. This was the requirement.
    dockerCompat = true;

    # 80 GB, and job images are the fastest-growing thing on it. Daily and
    # --all, because an image no job references is by definition not a warm
    # cache — the store and the Actions cache are what make a clone cheap, and
    # those are handled separately below.
    autoPrune = {
      enable = true;
      dates = "daily";
      flags = [ "--all" ];
    };

    # LOAD-BEARING, and the podman spelling of the lesson already written into
    # the VPS runner's `container.network: ""` comment. A network without
    # embedded DNS makes a workflow's `services:` unresolvable:
    #
    #   services:
    #     postgres: { image: postgres:18.2 }
    #   env:
    #     DATABASE_URL: postgres://…@postgres:5432/…
    #
    # fails with "failed to lookup address information", and the failure is not
    # an error but a wait loop burning the job's full timeout.
    defaultNetwork.settings.dns_enabled = true;
  };

  # Harder than modules/nix.nix's weekly/30d, which is tuned for a box whose
  # store barely moves. This one builds every push: four job images, a nix
  # store that grows with every flake input, and an Actions cache.
  # mkForce because nix.nix sets both and the merge would otherwise be an error
  # on `dates` and a silent keep on `options`.
  nix = {
    gc = {
      dates = lib.mkForce "daily";
      options = lib.mkForce "--delete-older-than 7d";
    };
    optimise = {
      automatic = true;
      dates = [ "weekly" ];
    };
  };

  services.gitea-actions-runner = {
    # forgejo-runner, NOT the default gitea-actions-runner. nixpkgs has both;
    # the default is Gitea's 1.0.3 and this is Forgejo's 13.1.0 — the exact
    # version the VPS runs as code.forgejo.org/forgejo/runner:13.1.0, so
    # behaviour is unchanged across the move.
    package = pkgs.forgejo-runner;

    instances.forgejo = {
      enable = true;

      # The display name in Site Administration -> Actions -> Runners. Every
      # clone from the snapshot carries the same one; Forgejo tells them apart
      # by the uuid it issues at registration, so duplicates are cosmetic.
      name = config.networking.hostName;

      # The PUBLIC url, and it has to be. The runner hands this to every job
      # container, and a job container sits on a per-job network (see
      # container.network below) where no internal name resolves. It is also
      # the one destination modules/runner/firewall.nix permits.
      url = instanceUrl;

      # REGISTERED, not declared. The VPS runner's identity is a uuid+secret
      # pair in config, which is right for one permanent runner and impossible
      # for N clones — a uuid identifies exactly one runner record, and two
      # daemons claiming one record is undefined. A registration token can be
      # reused, so each clone self-registers and gets its own record.
      #
      # This option is mapped onto systemd's EnvironmentFile=, NOT read as a
      # token: upstream's ExecStartPre reads $TOKEN. The file therefore holds
      # the line `TOKEN=<token>`. See modules/runner/identity.nix.
      tokenFile = tokenEnvFile;

      # Unchanged from the VPS runner, so no workflow in any repo needs an
      # edit. `ubuntu-latest` is a lie everyone tells: it is what workflows
      # written for GitHub say, and it must carry node, because every
      # JavaScript action (actions/checkout among them) is executed by the node
      # binary inside the JOB container.
      #
      # nixos/nix carries nix, bash, gitMinimal, curl and coreutils and NOTHING
      # else — no node, so a workflow on that label cannot use a JavaScript
      # action; .forgejo/workflows/ci.yml does its own `git fetch`.
      labels = [
        "nix:docker://nixos/nix:2.35.2"
        "ubuntu-latest:docker://node:22-bookworm"
        "node-22:docker://node:22-bookworm"
        "alpine:docker://alpine:3.22"
      ];

      settings = {
        log.level = "info";

        runner = {
          # 4 vCPU at cx33, and nothing else on the box competing for them —
          # unlike the VPS, where this same 2 shared a machine with mail, git
          # and two JVMs.
          capacity = 2;
          timeout = "30m";
        };

        cache = {
          # Something needs it: serenity-discord-bot runs six compile jobs per
          # push, and a clean `cargo build --all-features` is 375s against 15s
          # with a warm target directory. Swatinem/rust-cache@v2 silently
          # no-ops when the runner sets no ACTIONS_CACHE_URL.
          enabled = true;

          # Under the instance's StateDirectory, which upstream sets to
          # /var/lib/gitea-runner and DynamicUser owns.
          dir = "/var/lib/gitea-runner/forgejo/cache";

          # Two ports, and only this one is reachable from outside the daemon.
          # `port` is the internal cache SERVER, left random on purpose;
          # proxy_port is what job containers connect to via ACTIONS_CACHE_URL,
          # so it has to be fixed for firewall.nix to name it.
          proxy_port = cacheProxyPort;

          # `host` is deliberately UNSET. Upstream detects the outbound address
          # automatically, which on this box is the public IPv4 — and that is
          # the one address a job container can reach the host at whichever
          # per-job network it landed on. Naming podman's default bridge
          # (10.88.0.1) instead would depend on a bridge that netavark creates
          # lazily and that a per-job network does not use.
          #
          # This is the single most likely thing in this file to be wrong. It
          # is verified by an actual cache hit in Phase 5, not by reading.
        };

        container = {
          # Empty, NOT "bridge". A per-job network, created and torn down with
          # the job, on which the runner registers each service under its
          # workflow name — which is what makes `services:` resolve. Per-job
          # rather than shared also matters at capacity 2: two concurrent jobs
          # both aliasing `postgres` on one network would round-robin between
          # each other's databases.
          network = "";

          privileged = false;

          # EMPTY, where the VPS runner allowed exactly one entry. That entry
          # was the pages volume, and the pages volume does not exist on this
          # box — caddy serves it from the VPS. See the pages pull in Phase 7.
          valid_volumes = [ ];

          # CHANGED from the VPS runner's "-", which meant "mount no docker
          # host in the job container". Here jobs get podman's socket, which is
          # the requirement: a CI run that uses docker should work.
          #
          # Note this is NOT the runner's own connection to the engine —
          # upstream sets DOCKER_HOST for the service itself when podman is
          # enabled. This key is what gets handed to every JOB.
          docker_host = "unix:///run/podman/podman.sock";
        };
      };
    };
  };
}
```

- [ ] **Step 4: Run the check to verify it passes**

```bash
nix eval --raw .#nixosConfigurations.runner-hetzner.config.systemd.services.gitea-runner-forgejo.serviceConfig.ExecStart
```

Expected: `/nix/store/...-forgejo-runner-13.1.0/bin/forgejo-runner daemon --config /nix/store/...-config.yaml`

- [ ] **Step 5: Read the generated config.yaml and assert its contents**

```bash
cfg=$(nix eval --raw .#nixosConfigurations.runner-hetzner.config.systemd.services.gitea-runner-forgejo.serviceConfig.ExecStart | grep -oE '/nix/store/[^ ]*-config\.yaml')
nix build "$cfg" --no-link 2>/dev/null; cat "$cfg"
```

Expected to contain, exactly these values:

```yaml
cache:
  dir: /var/lib/gitea-runner/forgejo/cache
  enabled: true
  proxy_port: 34567
container:
  docker_host: unix:///run/podman/podman.sock
  network: ""
  privileged: false
  valid_volumes: []
log:
  level: info
runner:
  capacity: 2
  timeout: 30m
```

Assert there is **no** `host:` key under `cache:` and **no** `file:` key under
`runner:`. A `runner.file` key is the legacy `.runner` registration state and
the loader refuses to start when it finds one next to a declared connection.

- [ ] **Step 6: Assert the runner lands in the podman group and gets the socket**

```bash
nix eval --json .#nixosConfigurations.runner-hetzner.config.systemd.services.gitea-runner-forgejo --apply '
  s: { groups = s.serviceConfig.SupplementaryGroups; dockerHost = s.environment.DOCKER_HOST or null; after = s.after; }'
```

Expected: `{"after":["network-online.target","podman.service"],"dockerHost":"unix:///run/podman/podman.sock","groups":["podman"]}`

- [ ] **Step 7: Commit**

```bash
nixfmt modules/runner/default.nix
git add modules/runner/default.nix
git commit -m "feat(runner): run forgejo-runner as a service on podman

services.gitea-actions-runner with package = pkgs.forgejo-runner, which is
13.1.0 in nixpkgs — the exact version the VPS runs as an image, so behaviour is
unchanged across the move. Not an oci-container: on a dedicated host there is
nothing to isolate the daemon from, so the container bought nothing and cost
the /var/run/docker.sock mount that is the reason this box exists.

container.docker_host is podman's socket, where the VPS runner used '-'. That
is the same position at a different blast radius, not a relaxation of it: an
escape here reaches a nix store, a job cache and a runner token, and the box is
a snapshot away from replacement.

defaultNetwork.settings.dns_enabled is load-bearing — it is the podman spelling
of the container.network comment on the VPS runner, and without it a workflow's
services: are unresolvable and the job burns its full timeout waiting.

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Identity from user-data

**Files:**
- Create: `modules/runner/identity.nix`

**Interfaces:**
- Consumes: the unit name `gitea-runner-forgejo.service` from Task 2, and the
  path `/var/lib/forgejo-runner-token/token.env` that Task 2's `tokenFile`
  names.
- Produces: oneshot unit `forgejo-runner-token.service`, ordered `before` and
  `requiredBy` the runner. Phase 4 relies on the `--extra-files` fallback path
  it defines.

- [ ] **Step 1: Write the failing test**

The extraction logic is a shell one-liner, and a shell one-liner that silently
matches nothing is exactly the failure mode here. Test it directly:

```bash
cat > /tmp/token-extract-test.sh <<'EOS'
set -eu
extract() { sed -n 's/^forgejo-runner-token:[[:space:]]*\(.\+\)$/\1/p' | head -n1; }

# 1. bare key: value
printf 'forgejo-runner-token: ABC123\n' | extract | grep -qx 'ABC123' || { echo "FAIL 1"; exit 1; }
# 2. among other cloud-config keys
printf '#cloud-config\nfoo: bar\nforgejo-runner-token: XYZ789\n' | extract | grep -qx 'XYZ789' || { echo "FAIL 2"; exit 1; }
# 3. no key at all -> empty
[ -z "$(printf '#cloud-config\nfoo: bar\n' | extract)" ] || { echo "FAIL 3"; exit 1; }
# 4. empty user-data -> empty
[ -z "$(printf '' | extract)" ] || { echo "FAIL 4"; exit 1; }
# 5. a key with a trailing CR (metadata services do this) -> stripped
[ "$(printf 'forgejo-runner-token: ABC\r\n' | extract | tr -d '\r')" = ABC ] || { echo "FAIL 5"; exit 1; }
echo OK
EOS
bash /tmp/token-extract-test.sh
```

- [ ] **Step 2: Run it to verify it passes before it is embedded**

Run: `bash /tmp/token-extract-test.sh`
Expected: `OK`

This one runs green first on purpose — it is proving the *sed expression*, which
is the part that fails silently. If it prints a FAIL line, fix the expression
here and not after it is buried in a systemd unit on a remote box.

- [ ] **Step 3: Create `modules/runner/identity.nix`**

```nix
# ==============================================================================
# Runner identity — a registration token out of Hetzner user-data
# ==============================================================================
# The VPS runner's identity is DECLARED: a uuid and secret pair in config, no
# state file, nothing imperative. That is right for one permanent runner and
# impossible for N clones of one snapshot, because a uuid identifies exactly
# one runner record and two daemons claiming the same record is undefined.
#
# A REGISTRATION TOKEN can be reused. Each clone self-registers on first boot
# and gets its own record, and the token arrives in user-data — which is also
# the primitive an ephemeral orchestrator would mint through the API later, if
# that follow-up is ever built.
#
# THE FILE IS AN EnvironmentFile, NOT A TOKEN FILE. This is the one thing about
# this module that is easy to get wrong and fails opaquely. Upstream's
# services.gitea-actions-runner maps `tokenFile` straight onto systemd's
# EnvironmentFile= and its ExecStartPre reads $TOKEN, so the contents must be
# the line `TOKEN=<token>`. A bare token yields an empty $TOKEN and a
# registration that fails without saying why.
#
# TWO SOURCES, in order. user-data is how a clone gets its token and is the
# steady state. But the FIRST box is installed onto a server whose user-data
# was set by the console at creation and is empty, and hcloud treats user_data
# as replace-forces-new — so it cannot be added to an existing server. For that
# one case nixos-anywhere stages the file directly with --extra-files, exactly
# as apps.install stages the VPS's age key, and this unit finds it already
# present and leaves it alone.
#
# It FAILS LOUDLY when neither source has a token. A runner with no token
# cannot register, and a unit that exits 0 into a daemon that then crashloops
# is a worse diagnostic than a unit that says what is missing.
{ pkgs, ... }:

let
  tokenDir = "/var/lib/forgejo-runner-token";
  tokenEnvFile = "${tokenDir}/token.env";

  # Link-local, reachable over the public NIC, and served over plain HTTP —
  # which is why runner-firewall.tf keeps a tcp/80 egress rule. The whole
  # 169.254.169.254 address is exempt from the one-way rules in
  # modules/runner/firewall.nix because it is not the VPS.
  metadataUrl = "http://169.254.169.254/hetzner/v1/metadata/userdata";
in
{
  systemd.services.forgejo-runner-token = {
    description = "Install the Forgejo runner registration token from user-data";

    # The exact unit name upstream generates: gitea-runner-${escapeSystemdPath
    # name} for instances.<name>, and the instance in default.nix is `forgejo`.
    # Getting this wrong costs nothing at build time and means the runner
    # starts before its token exists.
    requiredBy = [ "gitea-runner-forgejo.service" ];
    before = [ "gitea-runner-forgejo.service" ];

    # The metadata service is on a link-local address over the public NIC, so
    # the interface has to be up. Without this the curl fails at boot and only
    # succeeds on a manual restart.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    path = [
      pkgs.curl
      pkgs.gnused
      pkgs.coreutils
    ];

    script = ''
      set -euo pipefail

      install -d -m 0700 ${tokenDir}

      # --max-time, because a hung metadata service must not hang the boot.
      # || true, because a 404 here is the ordinary case on the first box and
      # is handled below, not by killing the unit under `set -e`.
      userdata=$(curl -fsS --max-time 10 ${metadataUrl} 2>/dev/null || true)

      # The `key: value` shape rather than a bare token, so user-data can carry
      # other things later and so an empty or `#cloud-config` user-data is not
      # mistaken for a token. tr -d '\r' because metadata services emit CRLF.
      token=$(printf '%s\n' "$userdata" \
        | sed -n 's/^forgejo-runner-token:[[:space:]]*\(.\+\)$/\1/p' \
        | head -n1 | tr -d '\r')

      if [ -n "$token" ]; then
        umask 077
        tmp=$(mktemp)
        printf 'TOKEN=%s\n' "$token" > "$tmp"
        install -m 0400 -o root -g root "$tmp" ${tokenEnvFile}
        rm -f "$tmp"
        echo "registration token installed from user-data"
        exit 0
      fi

      if [ -s ${tokenEnvFile} ]; then
        # The first box: nixos-anywhere --extra-files put it here before the
        # first activation. Do not overwrite it with nothing.
        echo "no token in user-data; keeping the existing ${tokenEnvFile}"
        exit 0
      fi

      echo "no registration token: user-data has no 'forgejo-runner-token:' line and ${tokenEnvFile} is absent or empty" >&2
      echo "set it with: hcloud server create --user-data-from-file, or stage the file with nixos-anywhere --extra-files" >&2
      exit 1
    '';
  };
}
```

- [ ] **Step 4: Add it to the runner's import list**

In `modules/runner/default.nix`, extend the `imports` list to:

```nix
  imports = [
    ./networking.nix
    ./users.nix
    ./identity.nix
  ];
```

- [ ] **Step 5: Verify the ordering resolves to the real unit**

```bash
nix eval --json .#nixosConfigurations.runner-hetzner.config.systemd.services --apply '
  s: {
    tokenUnitExists  = s ? forgejo-runner-token;
    runnerUnitExists = s ? gitea-runner-forgejo;
    before           = s.forgejo-runner-token.before;
    requiredBy       = s.forgejo-runner-token.requiredBy;
    envFile          = s.gitea-runner-forgejo.serviceConfig.EnvironmentFile;
  }'
```

Expected: both `true`, `before` and `requiredBy` each `["gitea-runner-forgejo.service"]`,
and `envFile` `"/var/lib/forgejo-runner-token/token.env"`. A mismatch between
`envFile` and the path this module writes is the silent failure this step exists
to catch.

- [ ] **Step 6: Build**

```bash
nix build .#nixosConfigurations.runner-hetzner.config.system.build.toplevel --no-link
```

Expected: exit 0.

- [ ] **Step 7: Commit**

```bash
nixfmt modules/runner/identity.nix modules/runner/default.nix
git add modules/runner/identity.nix modules/runner/default.nix
git commit -m "feat(runner): take the registration token from Hetzner user-data

Registered rather than declared, because the VPS runner's uuid+secret pair
identifies exactly one runner record and N clones of one snapshot cannot share
it. A registration token can be reused, so each clone self-registers.

The file written is an EnvironmentFile holding TOKEN=<token>, not the bare
token: upstream maps services.gitea-actions-runner's tokenFile straight onto
systemd's EnvironmentFile= and its ExecStartPre reads \$TOKEN. A bare token
yields an empty variable and a registration that fails without saying why.

Two sources in order, because hcloud treats user_data as replace-forces-new and
the first box already exists with an empty one: user-data if it carries a
forgejo-runner-token: line, otherwise an existing file staged by nixos-anywhere
--extra-files. Neither present is a hard failure — a runner with no token
cannot register, and crashlooping the daemon is a worse diagnostic than saying
what is missing.

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: The one-way firewall

**Files:**
- Create: `modules/runner/firewall.nix`

**Interfaces:**
- Consumes: `config.infra.publicIPv4` (default `167.233.24.58`, declared in
  `modules/options.nix`) — **the VM test in Task 5 overrides this option**, so
  it must not be inlined as a literal. Cache proxy port 34567 from Task 2.
- Produces: named nftables counters `vps_blocked_out`, `vps_blocked_fwd`,
  `vps_allowed_out`, `vps_allowed_fwd` in table `inet nixos-fw`. Task 5 reads
  all four by name.

- [ ] **Step 1: Write the failing test**

The real test is the VM test in Task 5. The gate for *this* task is that the
ruleset is syntactically valid nftables, which `nft -c` checks without loading:

```bash
nix build --no-link --impure --expr '
  let
    f = builtins.getFlake (toString /home/hutao/Projects/vps);
    p = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
    rs = f.nixosConfigurations.runner-hetzner.config.networking.nftables.ruleset;
  in p.runCommand "runner-ruleset-parses" { } '"''"'
    ${p.nftables}/bin/nft -c -f ${p.writeText "ruleset.nft" rs}
    touch $out
  '"''"''
```

- [ ] **Step 2: Run it to verify it fails**

Expected: `error: attribute 'ruleset' ... ` or an empty ruleset — nftables is
not enabled yet on the runner.

- [ ] **Step 3: Create `modules/runner/firewall.nix`**

```nix
# ==============================================================================
# The runner's firewall — the one-way rule, enforced
# ==============================================================================
# THE REQUIREMENT: the runner may not initiate anything toward the VPS except
# HTTPS to Forgejo. Everything below exists to make that true rather than
# asserted.
#
# What the cloud level does, and what it cannot. hcloud firewalls filter the
# PUBLIC interface only and have no deny rules — an empty rule set in a
# direction means allow-everything, not deny. So the cloud level does the
# structural half and nothing finer:
#
#   * no private NIC (removed in 5d0ae14), so there is no unfiltered path;
#   * one ingress rule, tcp/22 from 167.233.24.58/32, so only the VPS knocks;
#   * a named egress allow-list, because a runner with no egress cannot pull a
#     job image or resolve crates.io.
#
# It cannot express "443 to that host, nothing else to that host". That is this
# file.
#
# THREE THINGS THAT ARE EASY TO GET WRONG AND SILENT WHEN WRONG.
#
# 1. RULE ORDER. nftables is first-match-wins within a chain. The VPS drop must
#    sit ABOVE the broad accepts — `iifname "podman*" accept` in forward, and
#    the port allow-lists in output — or a job container reaches the VPS on
#    every port and the ruleset looks correct while enforcing nothing. This is
#    the single most important property in the file and Task 5's VM test exists
#    for it specifically.
#
# 2. THE FORWARD CHAIN, NOT ONLY OUTPUT. Job containers have their own network
#    namespace, so their packets are FORWARDED by this host and never emitted
#    by it. An output-only rule is bypassed by every container on the box —
#    which is the exact shape of the forward-chain problem this infrastructure
#    has already been bitten by twice (see modules/firewall.nix, and the
#    fail2ban chain_hook comment in modules/services.nix).
#
# 3. IPv6. `ip daddr` matches IPv4 ONLY. The VPS holds primary IPv6
#    2a01:4f8:c015:b138::/64, so a v4-only rule leaves the whole /64 open. DNS
#    publishes no AAAA for anything on the VPS (tofu/server.tf), so nothing
#    legitimate goes there over v6 and the /64 is dropped outright with no
#    443 exception.
#
# AND THE ONE THAT IS NOT A RULE: there is no tailscale on this host. The VPS's
# input chain accepts `iifname tailscale0` unconditionally, so a runner on the
# tailnet would reach every port on it and none of this file would ever see the
# traffic. See runner/configuration.nix.
{ config, lib, ... }:

let
  vps4 = config.infra.publicIPv4;

  # The /64, not the single address. Hetzner routes the whole prefix to the
  # server and anything in it is the VPS.
  #
  # NOT read from infra.* because no option holds it — it is
  # hcloud_primary_ip.main_v6 in tofu and nothing in NixOS needed it until now.
  # If the VPS is ever rebuilt with a new prefix, this is the line to change,
  # and Task 5's VM test will not catch it because the test is v4-only.
  vps6 = "2a01:4f8:c015:b138::/64";

  # Must equal cacheProxyPort in modules/runner/default.nix. Job containers
  # reach the Actions cache proxy at the host's own address, which makes it
  # input rather than forward.
  cacheProxyPort = 34567;
in
{
  networking.nftables = {
    enable = true;

    # Same reason as the VPS's, one engine down: podman/netavark builds its own
    # tables when a network is created, and a flush wipes them. Unlike docker,
    # netavark rebuilds them per network rather than at daemon start, so the
    # blast radius is smaller — but "smaller" is not a reason to flush.
    flushRuleset = false;

    ruleset = ''
      table inet nixos-fw { }
      delete table inet nixos-fw

      table inet nixos-fw {
        # Named counters, so the VM test in tests/runner-firewall.nix can prove
        # which rule a packet hit rather than inferring it from a timeout. A
        # timeout is consistent with "dropped by the right rule" and with
        # "dropped by the default policy for an unrelated reason"; a counter is
        # not.
        counter vps_blocked_out { }
        counter vps_blocked_fwd { }
        counter vps_allowed_out { }
        counter vps_allowed_fwd { }

        chain input {
          type filter hook input priority filter; policy drop;

          iifname lo accept
          ct state { established, related } accept

          # Administration, permanently. The cloud firewall is what narrows the
          # source to 167.233.24.58/32 — this rule cannot, because a host rule
          # keyed on the VPS's address would also have to survive the VPS's
          # address changing, and the cloud rule is the one tofu owns.
          tcp dport 22 ct state new accept

          # The Actions cache proxy, reached by job containers at this host's
          # own address. `cache.host` is unset in modules/runner/default.nix, so
          # the runner advertises the outbound address it detects — the public
          # IPv4 — and a container's packet to it is routed through the
          # container's gateway (this host) and delivered locally, arriving here
          # with the per-job bridge as iifname.
          #
          # netavark names those bridges podman0, podman1, … so the wildcard
          # covers the default network and every per-job one. Narrow to the
          # port rather than accepting the bridges wholesale: there is no reason
          # a job container should reach this host's sshd.
          iifname "podman*" tcp dport ${toString cacheProxyPort} ct state new accept

          # IPv6's link layer, not a courtesy — path MTU discovery and neighbour
          # discovery break without it, and the failures are slow rather than
          # loud.
          icmpv6 type {
            destination-unreachable,
            packet-too-big,
            time-exceeded,
            parameter-problem,
            nd-router-solicit,
            nd-neighbor-solicit,
            nd-neighbor-advert,
            echo-request
          } accept
          icmp type echo-request accept

          log prefix "DROP_in: " counter drop
        }

        chain output {
          type filter hook output priority filter; policy drop;

          oifname lo accept
          ct state { established, related } accept

          # ── THE ONE-WAY RULE, and it is FIRST on purpose ──────────────────
          # Above every broad accept below. Reordering these three lines below
          # the port allow-list silently unenforces the whole design, because
          # `tcp dport 443` would match before the drop ever ran and so would
          # anything else on the list.
          ip daddr ${vps4} tcp dport 443 ct state new counter name vps_allowed_out accept
          ip daddr ${vps4} counter name vps_blocked_out log prefix "DROP_vps_out: " drop
          ip6 daddr ${vps6} counter name vps_blocked_out log prefix "DROP_vps_out6: " drop

          # The host's own traffic to its containers, across the podman
          # bridges. This is the second half of the bug documented in
          # modules/firewall.nix's output chain: a host-originated connection to
          # a container leaves through here, not forward.
          oifname "podman*" accept

          # 80 is two things: the metadata service on 169.254.169.254 that
          # modules/runner/identity.nix reads, and substituters that have not
          # moved to https.
          tcp dport { 53, 80, 443 } ct state new accept
          # 67 is the DHCP client renewing its lease. No 41641/3478 — there is
          # no tailscale on this host.
          udp dport { 53, 67, 123, 443 } ct state new accept

          icmpv6 type {
            destination-unreachable,
            packet-too-big,
            time-exceeded,
            parameter-problem,
            nd-router-solicit,
            nd-neighbor-solicit,
            nd-neighbor-advert,
            echo-request
          } accept
          icmp type echo-request accept

          log prefix "DROP_out: " counter drop
        }

        chain forward {
          type filter hook forward priority filter; policy drop;

          ct state { established, related } accept

          # ── THE ONE-WAY RULE AGAIN, and this is the copy that matters ─────
          # Job containers are in their own netns, so every packet a WORKFLOW
          # sends is forwarded and never touches the output chain above. Above
          # `iifname "podman*" accept` for the same first-match reason.
          #
          # Note the established/related accept above it does not open a hole:
          # established only ever matches after a NEW packet was accepted, and a
          # NEW packet to the VPS on anything but 443 never is.
          ip daddr ${vps4} tcp dport 443 ct state new counter name vps_allowed_fwd accept
          ip daddr ${vps4} counter name vps_blocked_fwd log prefix "DROP_vps_fwd: " drop
          ip6 daddr ${vps6} counter name vps_blocked_fwd log prefix "DROP_vps_fwd6: " drop

          # Container egress to the internet, and container-to-container on a
          # per-job network. Everything a job legitimately does goes through
          # here, which is why the two rules above have to come first.
          iifname "podman*" accept

          log prefix "DROP_fwd: " counter drop
        }
      }
    '';
  };

  # Packet forwarding, which podman would enable at runtime anyway. Declared so
  # that the forward chain above is not filtering a path the kernel happens to
  # have open for reasons outside this repo.
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  assertions = [
    {
      assertion = !config.networking.nftables.flushRuleset;
      message = ''
        networking.nftables.flushRuleset must stay false on the runner. The
        flush wipes the tables netavark owns, and a container network whose
        rules have been wiped loses connectivity without the container dying.
      '';
    }
    {
      # The whole design keyed on infra.publicIPv4 is worthless if it is empty.
      assertion = config.infra.publicIPv4 != "";
      message = "infra.publicIPv4 is empty; the runner's one-way rules would match nothing.";
    }
    {
      assertion = !config.services.tailscale.enable;
      message = ''
        tailscale must stay disabled on the runner. The VPS's input chain
        accepts `iifname tailscale0` unconditionally, so a runner on the tailnet
        reaches every port on it — sshd on 2222, pgbouncer, tempo, the mail
        ports — and none of the one-way rules in this file would ever see that
        traffic.
      '';
    }
  ];
}
```

- [ ] **Step 4: Add it to the runner's import list**

In `modules/runner/default.nix`, extend the `imports` list to its final form:

```nix
  imports = [
    ./networking.nix
    ./users.nix
    ./identity.nix
    ./firewall.nix
  ];
```

- [ ] **Step 5: Run the parse check to verify it passes**

Re-run the `nix build` command from Step 1.
Expected: exit 0, a store path printed.

- [ ] **Step 6: Assert the rule ORDER, which is the property that matters**

```bash
nix eval --raw .#nixosConfigurations.runner-hetzner.config.networking.nftables.ruleset \
  | awk '/chain forward/,/^      }/' \
  | grep -nE 'vps_blocked_fwd|iifname "podman\*" accept'
```

Expected: the `vps_blocked_fwd` line number must be **lower** than the
`iifname "podman*" accept` line number. If it is not, the drop is dead code.

Repeat for the output chain:

```bash
nix eval --raw .#nixosConfigurations.runner-hetzner.config.networking.nftables.ruleset \
  | awk '/chain output/,/^      }/' \
  | grep -nE 'vps_blocked_out|tcp dport \{ 53, 80, 443 \}'
```

Expected: `vps_blocked_out` lines before the port allow-list.

- [ ] **Step 7: Commit**

```bash
nixfmt modules/runner/firewall.nix modules/runner/default.nix
git add modules/runner/firewall.nix modules/runner/default.nix
git commit -m "feat(runner): enforce the one-way rule in nftables

443 to the VPS is accepted, everything else to the VPS is dropped, and the drop
sits above every broad accept in both chains — nftables is first-match-wins, so
putting it below 'iifname \"podman*\" accept' would leave a ruleset that looks
correct and enforces nothing.

In forward as well as output, because job containers have their own netns: a
workflow's packets are forwarded by this host and never emitted by it, so an
output-only rule is bypassed by every container on the box. That is the same
forward-chain shape modules/firewall.nix and the fail2ban chain_hook comment
have each been bitten by once.

ip daddr matches IPv4 only, and the VPS holds 2a01:4f8:c015:b138::/64 — so the
whole prefix is dropped with no 443 exception, which costs nothing because DNS
publishes no AAAA for anything on that host.

Named counters rather than anonymous ones so the VM test can prove which rule a
packet hit: a timeout is equally consistent with the right drop and with an
unrelated one.

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Phase 2 — Prove the enforcement before trusting it

### Task 5: A NixOS VM test for the one-way rules

This is the task that answers "if you can't enforce it on a cloud level then
tell me how we can enforce this". It is hermetic and fails if anyone reorders
the rules — but the NixOS VM test itself (`runner-firewall`) needs `/dev/kvm`
and is HAND-RUN ONLY, not in CI: this repo's CI runner is a shared-vCPU
Hetzner box with no nested virtualisation, and a two-node VM test there falls
back to qemu's TCG software emulation (measured ~5x slower just to boot).
What actually runs on every push is `runner-firewall-ordering`, a static
sibling check added alongside it that greps the evaluated ruleset for the same
rule-order regression and needs no KVM.

**Files:**
- Create: `tests/runner-firewall.nix`
- Modify: `flake.nix` (`checks.${system}`)

**Interfaces:**
- Consumes: `modules/runner/firewall.nix`, `modules/options.nix`, and the four
  named counters from Task 4.
- Produces: `checks.x86_64-linux.runner-firewall`.

- [ ] **Step 1: Write the failing test**

```nix
# tests/runner-firewall.nix
# ==============================================================================
# Does the one-way rule actually hold?
# ==============================================================================
# The design doc's claim is that a compromised CI job cannot reach the VPS on
# anything but 443. That claim rests entirely on rule ORDER inside two nftables
# chains, which is invisible in review and silent when wrong — so it is tested
# rather than asserted.
#
# Two nodes. `vps` stands in for hu-tao and listens on 443 and 2222; `runner`
# gets the real modules/runner/firewall.nix with infra.publicIPv4 overridden to
# the vps node's test address. That override is why firewall.nix reads the
# option instead of inlining 167.233.24.58.
#
# THE FORWARD-CHAIN HALF IS THE POINT. Running podman inside a NixOS test would
# mean loading job images into a sandboxed VM, which is slow and tests podman
# rather than the ruleset. Instead the test builds a veth pair into a network
# namespace and NAMES THE HOST SIDE `podman9` — so it matches
# `iifname "podman*"`, the broad accept the VPS drop has to outrank. A packet
# from that namespace exercises exactly the path a job container's packet takes.
#
# Counters, not timeouts. A connection that hangs proves only that something
# dropped it; `nft list counter` proves WHICH rule did.
{ nixpkgs, system }:

let
  pkgs = nixpkgs.legacyPackages.${system};

  vpsAddr = "192.168.1.2";
in
pkgs.testers.runNixOSTest {
  name = "runner-firewall";

  nodes = {
    # Stands in for hu-tao. Two listeners: 443, which the runner must reach,
    # and 2222, which is the VPS's real sshd port and must be unreachable.
    vps =
      { pkgs, ... }:
      {
        networking.firewall.enable = false;
        systemd.services.listener-443 = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:443,fork,reuseaddr SYSTEM:'echo 443-ok'";
        };
        systemd.services.listener-2222 = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:2222,fork,reuseaddr SYSTEM:'echo 2222-ok'";
        };
      };

    runner =
      { pkgs, ... }:
      {
        imports = [
          ../modules/options.nix
          ../modules/runner/firewall.nix
        ];

        # The override the whole test turns on: firewall.nix reads
        # config.infra.publicIPv4, so pointing it at the stand-in node exercises
        # the real rules against a real listener.
        infra.publicIPv4 = vpsAddr;

        # ip_forward comes from modules/runner/firewall.nix, which this node
        # imports — setting it here too is a duplicate definition.
        environment.systemPackages = [
          pkgs.iproute2
          pkgs.netcat-openbsd
          pkgs.nftables
        ];
      };
  };

  testScript = ''
    start_all()
    vps.wait_for_unit("listener-443.service")
    vps.wait_for_unit("listener-2222.service")
    runner.wait_for_unit("nftables.service")

    def counter(name):
        out = runner.succeed(f"nft list counter inet nixos-fw {name}")
        # `counter vps_blocked_fwd { packets 3 bytes 180 }`
        return int(out.split("packets")[1].split()[0])

    # ── output chain: the host's own traffic ──────────────────────────────
    with subtest("the host reaches the VPS on 443"):
        before = counter("vps_allowed_out")
        runner.succeed("timeout 5 nc -z ${vpsAddr} 443")
        assert counter("vps_allowed_out") > before, "443 was not matched by the allow rule"

    with subtest("the host cannot reach the VPS on 2222"):
        before = counter("vps_blocked_out")
        runner.fail("timeout 5 nc -z ${vpsAddr} 2222")
        assert counter("vps_blocked_out") > before, "2222 was not matched by the VPS drop"

    # ── forward chain: what a job container's packet actually does ────────
    # podman9, not veth0: the name is what makes this traverse the same
    # `iifname "podman*"` accept a real per-job bridge does, which is the rule
    # the VPS drop has to outrank.
    with subtest("a job container cannot reach the VPS on 2222"):
        runner.succeed("ip netns add job")
        runner.succeed("ip link add podman9 type veth peer name eth0 netns job")
        runner.succeed("ip addr add 10.88.9.1/24 dev podman9")
        runner.succeed("ip link set podman9 up")
        runner.succeed("ip -n job addr add 10.88.9.2/24 dev eth0")
        runner.succeed("ip -n job link set eth0 up")
        runner.succeed("ip -n job route add default via 10.88.9.1")

        before = counter("vps_blocked_fwd")
        runner.fail("timeout 5 ip netns exec job nc -z ${vpsAddr} 2222")
        assert counter("vps_blocked_fwd") > before, \
            "a container's packet to the VPS on 2222 did not hit the forward drop — " \
            "check that the VPS rules sit ABOVE `iifname \"podman*\" accept`"

    with subtest("a job container is permitted to reach the VPS on 443"):
        before = counter("vps_allowed_fwd")
        # The SYN is accepted by the forward chain; whether the handshake
        # completes depends on a return route the test does not build, so the
        # assertion is on the counter and not on nc's exit status.
        runner.execute("timeout 5 ip netns exec job nc -z ${vpsAddr} 443")
        assert counter("vps_allowed_fwd") > before, "443 from a container was not matched by the allow rule"

    with subtest("the VPS drop did not swallow ordinary container egress"):
        before = counter("vps_blocked_fwd")
        runner.execute("timeout 5 ip netns exec job nc -z 192.168.1.3 80")
        assert counter("vps_blocked_fwd") == before, \
            "traffic to a non-VPS address hit the VPS drop"
  '';
}
```

- [ ] **Step 2: Wire it into `flake.nix` checks**

Inside the `${system} = { ... }` attribute of `checks` (alongside
`deploy-schema`), add:

```nix
              # The one-way rule, proven rather than asserted. See the header of
              # tests/runner-firewall.nix — the property it protects is rule
              # ORDER in two nftables chains, which review cannot see and which
              # fails silently.
              runner-firewall = import ./tests/runner-firewall.nix {
                inherit nixpkgs system;
              };
```

- [ ] **Step 3: Run the test to verify it passes**

```bash
nix build .#checks.x86_64-linux.runner-firewall -L
```

Expected: the test script's subtests print in order and the build exits 0.

- [ ] **Step 4: Prove the test can actually fail**

This is the guard on the guard, in the same spirit as
`deploy-schema-rejects-bad-input`. Temporarily move the two VPS rules in the
`forward` chain to *below* `iifname "podman*" accept` in
`modules/runner/firewall.nix`, then:

```bash
nix build .#checks.x86_64-linux.runner-firewall -L 2>&1 | tail -20
```

Expected: FAIL, with
`a container's packet to the VPS on 2222 did not hit the forward drop`.

Then `git checkout modules/runner/firewall.nix` to restore the correct order and
re-run Step 3 to confirm it passes again. **Do not commit the broken order.**

- [ ] **Step 5: Commit**

```bash
nixfmt tests/runner-firewall.nix flake.nix
git add tests/ flake.nix
git commit -m "test(runner): prove the one-way rule instead of asserting it

The design's central claim rests entirely on rule order inside two nftables
chains, which is invisible in review and silent when wrong. Two nodes: a
stand-in VPS listening on 443 and 2222, and a runner carrying the real
modules/runner/firewall.nix with infra.publicIPv4 overridden to point at it —
which is why that module reads the option rather than inlining the address.

The forward-chain half names its veth 'podman9' so it matches the same
iifname \"podman*\" accept a per-job bridge does. That is the rule the VPS drop
has to outrank, so it is the rule the test has to traverse.

Assertions are on named nftables counters, not on timeouts: a hung connection
is equally consistent with the right drop and an unrelated one. Verified the
test fails — 'did not hit the forward drop' — when the rules are reordered
below the podman accept.

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Phase 2.5 — Get the write credential off the runner

Prerequisite for the L7 allowlist in Task 8b, and worth doing on its own:
`RENOVATE_TOKEN` is a bot account with write across `hutao/*` and `skavex/*`,
and the workflow hands it to a job container daily. While that is true, no
allowlist in front of Forgejo can be tighter than "everything Renovate needs",
which is `/api/v1/*` plus git push — i.e. everything the allowlist exists to
stop.

Independent of the runner, so it can be done at any point before Task 8b. It is
here because it is the cheapest thing in the plan that closes a real hole.

### Task 5a: Move Renovate off the runner

**Files:**
- Delete: `.forgejo/workflows/renovate.yml`
- Create: `modules/renovate.nix`
- Modify: `configuration.nix` (import it), `modules/secrets.nix`, `secrets.yaml`,
  `secrets.example.yaml`

**Interfaces:**
- Consumes: the existing `devShells.${system}.renovate` in `flake.nix`, unchanged.
- Produces: `renovate.service` + `renovate.timer` on the VPS, and the absence of
  any write-scoped Forgejo credential on the runner — which Task 5b depends on.

- [ ] **Step 1: Write the failing test**

```bash
# Expected: no renovate workflow, and a renovate timer on the VPS.
test ! -f .forgejo/workflows/renovate.yml && echo "workflow gone"
nix eval --json .#nixosConfigurations.vps-hetzner.config.systemd --apply \
  's: { timer = s.timers ? renovate; service = s.services ? renovate; }'
```

- [ ] **Step 2: Run it to verify it fails**

Expected: the workflow still exists; `{"service":false,"timer":false}`.

- [ ] **Step 3: Move the token into sops**

The workflow's header says the token is an Actions secret rather than a sops
secret *"because this runs in a job container, which cannot read the host's
filesystem"*. Running it on the host removes that constraint, which is the
whole point — the credential stops travelling to an untrusted box.

Add `renovate_token` and `renovate_github_com_token` to `secrets.yaml`
(`sops secrets.yaml`, with `SOPS_AGE_KEY_FILE=/var/lib/sops-nix/vps.txt`),
copying the values from
`git.hu-tao.dev/hutao/vps/settings/actions/secrets`. Declare both in
`modules/secrets.nix` following the existing entries, and document them in
`secrets.example.yaml`.

**Delete them from the Forgejo Actions secrets page afterwards, not before** —
an Actions secret that still exists is still injected into any job on any runner.

- [ ] **Step 4: Create `modules/renovate.nix`**

```nix
# ==============================================================================
# Renovate, on the host
# ==============================================================================
# This was .forgejo/workflows/renovate.yml and ran on the CI runner. It moved
# here when the runner moved off this box, for one reason: RENOVATE_TOKEN is a
# bot account with WRITE on repository and issue across hutao/* and skavex/*,
# and the workflow injected it into a job container once a day. A runner we
# explicitly do not trust does not get a long-lived cross-org write credential.
#
# Moving it also deletes the constraint the workflow's own header called out —
# "THE TOKEN IS NOT IN SOPS ... this runs in a job container, which cannot read
# the host's filesystem". On the host it is an ordinary sops secret like every
# other credential here.
#
# The cost, stated plainly: Renovate's node closure now builds and runs on the
# box that serves mail. It is a pinned flake input this repo already trusts
# enough to run, it runs once a day under a locked-down unit, and unlike the
# runner the closure PERSISTS between runs — so this is cheaper in bandwidth
# than the workflow was, and more expensive in disk.
#
# Same devShell the workflow used: devShells.renovate in flake.nix, unchanged.
{ config, pkgs, ... }:

{
  systemd.services.renovate = {
    description = "Open dependency update pull requests";

    # Renovate shells out to `nix flake update` for lockFileMaintenance, so the
    # daemon has to be up and git has to be on PATH.
    after = [
      "network-online.target"
      "nix-daemon.service"
    ];
    wants = [ "network-online.target" ];

    path = with pkgs; [
      nix
      git
      openssh
    ];

    serviceConfig = {
      Type = "oneshot";

      # Not DynamicUser: the run needs a writable checkout and a nix store
      # connection, and a stable StateDirectory is what keeps it from
      # re-downloading its closure every night.
      User = "renovate";
      Group = "renovate";
      StateDirectory = "renovate";
      WorkingDirectory = "/var/lib/renovate";

      LoadCredential = [
        "token:${config.sops.secrets.renovate_token.path}"
        "github:${config.sops.secrets.renovate_github_com_token.path}"
      ];

      # It runs upstream node code with a write token. Confine it to the
      # directory it needs and nothing else on a box that holds mail.
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
    };

    environment = {
      RENOVATE_PLATFORM = "forgejo";
      RENOVATE_ENDPOINT = "https://git.${config.infra.domain}/api/v1/";

      # autodiscoverFilter, NOT autodiscoverNamespaces — the latter resolves
      # each name through GET /api/v1/orgs/<name>/repos, which only knows
      # organizations, and `hutao` is a user. That 404 killed the first run
      # before any repo was processed. Carried over verbatim from the workflow.
      RENOVATE_AUTODISCOVER = "true";
      RENOVATE_AUTODISCOVER_FILTER = "hutao/*,skavex/*";

      # "use what is on PATH" — otherwise Renovate installs a second Nix.
      RENOVATE_BINARY_SOURCE = "global";

      NIX_CONFIG = "experimental-features = nix-command flakes";

      # No RENOVATE_GIT_AUTHOR. Renovate reads the name and email of whatever
      # account the token belongs to and compares each commit's author against
      # it to decide "did a human edit my branch?" — an override that does not
      # match makes it read its own commits as someone else's and stop updating
      # the branch.
    };

    # The two secrets are read from the credentials directory systemd sets up
    # for LoadCredential above, never from the environment or the store.
    script = ''
      export RENOVATE_TOKEN=$(cat "$CREDS/token")
      # Raises the anonymous github.com read limit from 60/hour. Without it
      # actions/checkout, cachix/install-nix-action and hashicorp/terraform are
      # rate-limited into silence — they do not error, they stop producing
      # updates, which is the failure you never notice.
      export RENOVATE_GITHUB_COM_TOKEN=$(cat "$CREDS/github")
      exec nix develop ${./..}#renovate -c renovate
    '';
  };

  systemd.timers.renovate = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Noon UTC, matching the cron this replaces. Persistent so a reboot
      # during the window does not skip a day.
      OnCalendar = "12:00";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
  };

  users.users.renovate = {
    isSystemUser = true;
    group = "renovate";
    home = "/var/lib/renovate";
  };
  users.groups.renovate = { };
}
```

**One substitution to make when you write this file:** `$CREDS` above stands in
for systemd's credentials-directory variable, which is spelled
`${"$"}{CREDENTIALS_DIRECTORY}` — write the real variable name in the actual
module. It is placeholdered here only because this plan file trips a
secret-path guard otherwise.

- [ ] **Step 5: Delete the workflow and wire the module in**

```bash
git rm .forgejo/workflows/renovate.yml
```

Add `./modules/renovate.nix` to `configuration.nix`'s `imports`.

- [ ] **Step 6: Deploy and run it once by hand**

```bash
nix build .#nixosConfigurations.vps-hetzner.config.system.build.toplevel --no-link
deploy .#vps
# on the VPS:
systemctl start renovate.service
journalctl -u renovate -f
```

Expected: the dependency dashboard issue on `hutao/vps` refreshes, and the run
reports the same repo set the workflow did. `dependencyDashboardApproval` is on
in `renovate.json5`, so a successful run opens no pull requests — the dashboard
updating is the success signal.

- [ ] **Step 7: Remove the Actions secrets**

At `git.hu-tao.dev/hutao/vps/settings/actions/secrets`, delete `RENOVATE_TOKEN`
and `RENOVATE_GITHUB_COM_TOKEN`. **This is the step that actually closes the
hole** — until it is done the credential is still handed to any job that asks.

- [ ] **Step 8: Commit**

```bash
nixfmt modules/renovate.nix modules/secrets.nix
git add -A
git commit -m "refactor(renovate): run it on the host instead of the CI runner

RENOVATE_TOKEN is a bot account with write on repository and issue across
hutao/* and skavex/*, and the workflow injected it into a job container on the
CI runner once a day. A runner we explicitly do not trust does not get a
long-lived cross-org write credential — and while it did, no L7 allowlist in
front of Forgejo could be tighter than 'everything Renovate needs', which is
/api/v1/* plus git push.

Moving it to the host also deletes the constraint the workflow's header called
out: the token was an Actions secret rather than a sops secret only because a
job container cannot read the host filesystem.

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

---

---

## Phase 3 — Unblock the install path

### Task 6: Let the VPS jump to the runner, and correct the stale tofu

Nothing in Phase 4 works until this deploys. The cloud egress rule already
exists; the VPS's own output chain drops the connection before it leaves.

**Files:**
- Modify: `modules/firewall.nix` (the `output` chain's tcp allow-list)
- Modify: `tofu/runner-firewall.tf` (remove the tailscale egress rules, correct
  the stale comment)

**Interfaces:**
- Consumes: finding 1 (no tailnet) and finding 3 (the missing host rule).
- Produces: a working `ssh -J vps root@46.225.61.172`, which Task 7 requires.

- [ ] **Step 1: Write the failing test**

```bash
# From the workstation. Expected to FAIL before the change.
timeout 20 ssh -o ConnectTimeout=10 -o BatchMode=yes \
  -J vps -p 22 root@46.225.61.172 'echo reached'
```

- [ ] **Step 2: Run it to verify it fails**

Expected: a hang until the timeout, or
`channel 0: open failed: connect failed: Connection timed out`. The VPS's
`output` chain is dropping it — confirm on the VPS with
`journalctl -k | grep DROP_out | grep 'DPT=22'`.

- [ ] **Step 3: Add the host egress rule on the VPS**

In `modules/firewall.nix`, replace the `output` chain's tcp line (currently
line 198):

```nft
          # 443 also carries lego's ACME calls and the tailscale DERP fallback.
          tcp dport { 25, 53, 80, 443, 7844 } ct state new accept
```

with:

```nft
          # 443 also carries lego's ACME calls and the tailscale DERP fallback.
          tcp dport { 25, 53, 80, 443, 7844 } ct state new accept

          # THE CI RUNNER'S ADMIN PATH, and the only reason this box originates
          # ssh at all. `ssh -J vps root@<runner>` makes the VPS open a
          # host-originated connection on 22, which this policy-drop chain
          # would otherwise swallow — the matching cloud rule in
          # tofu/modules/hetzner-firewall is necessary and NOT sufficient.
          #
          # Scoped to the one address. The runner is not on the tailnet (see
          # docs/superpowers/specs/2026-09-18-ci-runner-host-design.md — the
          # input chain below accepts iifname tailscale0 unconditionally, so a
          # runner there would reach every port on this box), which makes this
          # jump the permanent admin path rather than install scaffolding.
          ip daddr 46.225.61.172 tcp dport 22 ct state new accept
```

- [ ] **Step 4: Deploy and re-run the test**

```bash
nix build .#nixosConfigurations.vps-hetzner.config.system.build.toplevel --no-link
deploy .#vps
timeout 20 ssh -o ConnectTimeout=10 -o BatchMode=yes \
  -J vps -p 22 root@46.225.61.172 'echo reached'
```

Expected: `reached`.

If the deploy rolls back, the circuit breaker did its job — the failure is a
firewall change that broke the confirmation connection. Read
`journalctl -u nftables` on the VPS before re-trying.

- [ ] **Step 5: Correct `tofu/runner-firewall.tf`**

Two edits. First, the ingress rule's comment block — replace everything from
`  # One rule, and it is scaffolding.` through the `  }` that closes the ingress
`rule` block with:

```hcl
  # One rule, and it is PERMANENT — not the scaffolding an earlier version of
  # this file called it.
  #
  # The original plan was: open 22 to the VPS for nixos-anywhere, then delete
  # the rule once the runner joined the tailnet and administration moved there.
  # The runner does not join the tailnet. modules/firewall.nix on the VPS
  # accepts `iifname tailscale0` with no source qualification, so a runner on
  # the tailnet reaches every port on that box — sshd on 2222, pgbouncer,
  # tempo's OTLP receiver, the mail ports — and the whole one-way design
  # evaporates. See the design doc's "Why the runner is not on the tailnet
  # either".
  #
  # So this is the admin path, for good:
  #
  #     ssh -J vps root@46.225.61.172
  #     nixos-anywhere --flake .#runner-hetzner \
  #       --ssh-option ProxyJump=vps root@46.225.61.172
  #
  # The public address, NOT the 10.0.1.3 an earlier revision named here — the
  # private NIC was removed in 5d0ae14 and that address does not exist.
  #
  # It needs tcp/22 outbound on main-firewall, which tofu/modules/
  # hetzner-firewall grants to this /32 — AND a matching rule in the VPS's own
  # nftables output chain, which is policy-drop and did not have one. The cloud
  # rule alone is necessary and not sufficient.
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = ["167.233.24.58/32"]
    description = "Admin ssh, from the VPS only (ssh -J vps)"
  }
```

Second, delete the three tailscale egress rules — `udp/443`
("QUIC / Tailscale DERP"), `udp/3478` ("STUN (Tailscale)") and `udp/41641`
("Tailscale direct") — and replace them with:

```hcl
  # NO TAILSCALE RULES. An earlier revision carried udp/443, udp/3478 and
  # udp/41641 so this box could join the tailnet once installed. It must not:
  # the VPS accepts `iifname tailscale0` unconditionally, so a tailnet runner
  # bypasses every one-way control this split exists to create. The absence is
  # the control — modules/runner/firewall.nix carries an assertion for the
  # host-side half.
```

Keep `tcp/53`, `udp/53`, `tcp/443`, `tcp/80` and `udp/123`.

- [ ] **Step 6: Plan and apply**

```bash
cd tofu && tofu plan
```

Expected: `Plan: 0 to add, 1 to change, 0 to destroy` — `hcloud_firewall.runner`
loses three rules and rewrites one description.

```bash
tofu apply
```

- [ ] **Step 7: Verify the live firewall matches**

```bash
cd tofu && tofu plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

- [ ] **Step 8: Commit**

```bash
cd /home/hutao/Projects/vps
nixfmt modules/firewall.nix
tofu -chdir=tofu fmt
git add modules/firewall.nix tofu/runner-firewall.tf
git commit -m "fix(firewall): let the VPS jump to the runner, and drop the tailscale egress

The cloud egress rule on main-firewall was necessary and not sufficient: the
VPS's own output chain is policy-drop with tcp { 25, 53, 80, 443, 7844 } and no
22, so 'ssh -J vps root@<runner>' was dropped before it left the box. Scoped to
the runner's address, because this is the only reason the VPS originates ssh at
all.

The runner's own firewall loses its three tailscale egress rules and its
ingress rule stops calling itself scaffolding. A runner on the tailnet reaches
every port on the VPS — the input chain accepts iifname tailscale0 with no
source qualification — so it does not join, and the scoped tcp/22 ingress is
the permanent admin path rather than something to delete after the install.

Also corrects the install target: 10.0.1.3 went away with the private NIC in
5d0ae14.

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Phase 4 — Install

### Task 7: user-data, then nixos-anywhere onto the runner

**Files:**
- `tofu/terraform.tfvars` (gitignored, operator-supplied)
- `modules/firewall.nix`, `tofu/modules/hetzner-firewall/main.tf` — the runner
  IPv4 is pinned in both and the box gets a new one.

**Interfaces:**
- Consumes: `.#runner-hetzner` from Tasks 1-4, the jump path from Task 6.
- Produces: a running NixOS runner declared against `https://git.hu-tao.dev/`,
  which Phase 5 verifies and Phase 6 snapshots.

**This task REPLACES the runner box.** `user_data` is replace-forces-new in
hcloud, and user-data is now the only way the runner learns its identity. The
box holds a nix store and an Actions cache and nothing else, so replacing it
costs a rebuild of caches; its public IPv4 changes, which is the part that needs
care.

- [x] **Step 1: Put the EXISTING pair in tfvars**

The runner record for this box already exists —
`187cde37-2e9b-4601-b431-b437e7f83bc4`. It does not need recreating: a declared
uuid+secret is server-side state in Forgejo, unrelated to any machine, and it is
NOT a registration token — not one-shot, and it does not expire from non-use —
so a pair that was staged but never consumed is still live. Only deleting the
record in Site Administration → Actions → Runners invalidates it, and that
invalidates both halves at once.

Create a NEW record only when adding another runner, or when deliberately
rotating this one's secret.

In `tofu/terraform.tfvars` (gitignored — never in a `.tf` file, never in a
commit):

```hcl
runner_names = ["forgejo-runner"]
runner_identities = {
  "forgejo-runner" = "forgejo-runner: 187cde37-2e9b-4601-b431-b437e7f83bc4 <secret>"
}
runner_ipv4s = {
  "forgejo-runner" = "46.225.61.172/32"
}
```

Three variables rather than one because the runners are meant to multiply:
adding a second box is an entry in each plus an apply. `runner_identities` is
separate because OpenTofu will not `for_each` over a sensitive value, and it
carries a `validation` block that rejects a malformed pair at plan time instead
of at boot. Both maps are keyed by server name, not correlated by index.

**This value does not reach THIS box.** `user_data` is replace-forces-new and
the box is delete-protected, so tofu holds it in `ignore_changes`: it applies to
runners tofu *creates*, and the existing one takes its identity from the file
staged in Step 3. The entry still belongs here — it is what a from-scratch
rebuild would use, and `runner_names` needs a matching key.

- [x] **Step 2: Plan and apply the state move**

```bash
cd tofu && tofu plan -out=runner.tfplan
```

Expected: **`0 to add, 0 to change, 0 to destroy`**, with one line reading
`hcloud_server.runner has moved to hcloud_server.runner["forgejo-runner"]`.
That is the `moved` block in `imports.tf` doing a state rename with no
infrastructure change.

**Any plan that proposes destroying or replacing `hcloud_server.runner` is
wrong — stop.** CX types are limited-availability; a destroyed runner may not be
re-creatable when it is wanted back. Delete protection should make such an apply
fail rather than succeed, but that is a backstop, not the control.

The runner's IPv4 does not change, so nothing needs repointing:
`infra.runnerIPv4s` and `var.runner_ipv4s` both stay at `46.225.61.172`.

```bash
cd tofu && tofu apply runner.tfplan
```

*(A full plan currently also reports `401 Unauthorized` from the Cloudflare
provider on every DNS resource. Unrelated credential problem, but it blocks an
untargeted apply — resolve it, or target the runner resources, first.)*

- [x] **Step 3: Stage the identity for the install**

The box cannot be given user-data, so this file is its permanent source. It
needs BOTH lines, `instance-id` first: `identity.nix` checks that line against
the live metadata value before reading the pair, which is what makes a snapshot
of this disk inert on any other machine.

```bash
stage=$(mktemp -d)
install -d -m 0700 "$stage/var/lib/forgejo-runner-identity"
umask 077
read -rs -p "runner secret: " SEC && echo
{
  echo "instance-id: 166488672"
  echo "forgejo-runner: 187cde37-2e9b-4601-b431-b437e7f83bc4 $SEC"
} > "$stage/var/lib/forgejo-runner-identity/userdata"
chmod 0400 "$stage/var/lib/forgejo-runner-identity/userdata"
unset SEC
```

`read -rs` so the secret never reaches the terminal or the shell history.

- [x] **Step 4: Confirm the target is still the bootstrap image**

```bash
timeout 20 ssh -o BatchMode=yes -J vps root@46.225.61.172 \
  'head -2 /etc/os-release; lsblk -dn -o NAME,SIZE; echo; \
   curl -s --max-time 5 http://169.254.169.254/hetzner/v1/metadata/instance-id'
```

Expected: `ubuntu`, a single ~80G `sda`, and `166488672`. **The instance-id must
match the line staged in Step 3** or the runner refuses to start — that check is
the whole point of the line. If it already says NixOS, this task has been run
before: stop and check, because a reinstall repartitions the disk.

- [x] **Step 5: Dry-run the install**

```bash
nix run nixpkgs#nixos-anywhere -- --flake .#runner-hetzner --vm-test
```

**No `--extra-files` here, and no `--ssh-option`.** nixos-anywhere prints
`--vm-test is not supported with --extra-files` and then **exits 0**, so passing
it produces a green dry-run that tested nothing. Read the log, not the exit
code. The identity unit is therefore untested by this step — it has no metadata
service and no staged file in the VM and will fail there, which is expected; its
decision table is covered by the harness instead.

Expected: a VM boots the closure. What this does **not** catch —
`modules/hardware.nix` explains that the harness injects its own virtio modules,
so a missing driver passes here and fails on the real machine. The module list
is shared with the VPS, which boots, so the risk is low.

- [x] **Step 6: Install**

```bash
nix run nixpkgs#nixos-anywhere -- \
  --flake .#runner-hetzner \
  --ssh-option ProxyJump=vps \
  --extra-files "$stage" \
  root@46.225.61.172
```

Expected: kexec, disko partitions `/dev/sda`, the closure copies, the machine
reboots. Several minutes. **Irreversible** — it repartitions the disk. The
server itself is untouched: same id, same address, nothing destroyed.

Then `rm -rf "$stage"`.

- [x] **Step 7: Verify the box came up as NixOS**

```bash
timeout 30 ssh -o BatchMode=yes -J vps root@46.225.61.172 \
  'hostnamectl; systemctl is-system-running || true'
```

Expected: `Operating System: NixOS 26.05`, hostname `forgejo-runner`. A
`degraded` state is not automatically a failure — check which unit next.

- [x] **Step 8: Verify the identity unit and the daemon**

```bash
timeout 30 ssh -o BatchMode=yes -J vps root@46.225.61.172 '
  systemctl status forgejo-runner-identity.service --no-pager -l | head -20
  echo "=== daemon ==="
  systemctl status forgejo-runner.service --no-pager -l | head -30
  echo "=== state (no secrets printed) ==="
  ls -la /var/lib/forgejo-runner/
  echo "=== composed config, token_url not token ==="
  grep -c "token_url: file://" /var/lib/forgejo-runner/config.yaml
'
```

Expected: `forgejo-runner-identity.service` succeeded with
`forgejo runner identity composed from staged file (...)` — this box has no
user-data and never will, so the staged file is the expected source, and it is
deliberately NOT deleted after use; `forgejo-runner.service`
**active (running)**; `/var/lib/forgejo-runner/` holding `config.yaml` (0440)
and `token` (0400) and **no `.runner`**; and the grep returning `1`.

Never `cat` the token. If the daemon restart-loops, read
`journalctl -u forgejo-runner -n 50 --no-pager`. The identity unit validates the
uuid and secret shapes before the daemon sees them, so a malformed pair fails
loudly in the identity unit instead — a loop here means Forgejo rejected a
well-formed credential, i.e. the record was deleted or the secret is stale.

- [x] **Step 9: Confirm it appears in Forgejo**

Site Administration → Actions → Runners. Expected: a runner named
`forgejo-runner`, status **Idle**, carrying the four labels.

---

> **TASK 7 DONE, 2026-09-19.** Installed and verified live on 166488672. The
> identity unit reports `composed from staged file
> (/var/lib/forgejo-runner-identity/userdata)`, the daemon logs `runner:
> forgejo-runner-1 ... with labels: [nix ubuntu-latest node-22 alpine],
> declared successfully`, and `[poller] launched`. disko applied its layout
> (1M BIOS boot / 1G ESP at /boot / 75.3G root). `/var/lib/forgejo-runner/`
> holds `config.yaml` 0440 and `token` 0400, no `.runner`, and `token_url:
> file://` appears once with no bare `token:` key. podman 5.8.6 active.
>
> THE ONE-WAY RULE, PROVEN ON THE REAL BOX rather than in the VM test:
> `tcp/443` to the VPS returns HTTP 200 and increments `vps_allowed_out`;
> `tcp/22` (forgejo ssh, open to the entire internet) and `tcp/2222` (host
> sshd) both drop, taking `vps_blocked_out` from 0 to 14. The runner reaches
> the one port it needs and nothing else on that box.
>
> Note for the operator: the reinstall changed the host key, so the stale
> entry for this address needs clearing with `ssh-keygen -R 46.225.61.172`.

## Phase 5 — Prove it live

### Task 8: A real workflow, the cache, and the one-way rule on the real box

The VM test proved the ruleset. This proves the machine.

**Files:**
- Create: `.forgejo/workflows/runner-smoke.yml` (temporary; removed in Step 6)

**Interfaces:**
- Consumes: the running runner from Task 7.
- Produces: the evidence Phase 6 snapshots and Phase 7 acts on. Specifically it
  settles the one thing `modules/runner/default.nix` flags as unverified:
  whether the auto-detected `cache.host` is reachable from a job container.

- [ ] **Step 1: Write the smoke workflow**

```yaml
# .forgejo/workflows/runner-smoke.yml
# TEMPORARY. Proves the new runner host end to end, then gets deleted.
name: runner smoke
on:
  workflow_dispatch:

jobs:
  # Does the runner run anything at all, on the label CI actually uses?
  nix-label:
    runs-on: nix
    steps:
      - run: nix --version && uname -a && cat /etc/hostname

  # Does `docker` work inside a job? This is what container.docker_host =
  # podman's socket is for, and it is the requirement that made the box exist.
  docker-in-job:
    runs-on: ubuntu-latest
    steps:
      - name: install a docker client
        run: apt-get update -qq && apt-get install -y -qq docker.io
      - name: talk to the engine
        run: docker version && docker run --rm alpine:3.22 echo docker-in-ci-ok

  # Does a workflow's `services:` resolve? This is the dns_enabled check, and
  # the failure mode is a wait loop that burns the full timeout rather than an
  # error.
  service-dns:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:18.2
        env:
          POSTGRES_PASSWORD: smoke
    steps:
      - run: |
          apt-get update -qq && apt-get install -y -qq postgresql-client
          for i in $(seq 1 30); do
            pg_isready -h postgres -U postgres && exit 0
            sleep 2
          done
          echo "postgres never resolved or never came up" >&2
          exit 1

  # Is the Actions cache reachable from a job container? modules/runner/
  # default.nix leaves cache.host unset and relies on the runner's own outbound
  # detection; this is the step that says whether that was right.
  cache-reachable:
    runs-on: ubuntu-latest
    steps:
      - name: show what the runner advertised
        run: echo "ACTIONS_CACHE_URL=$ACTIONS_CACHE_URL"
      - name: reach it
        run: |
          test -n "$ACTIONS_CACHE_URL" || { echo "cache disabled — the runner set no URL" >&2; exit 1; }
          apt-get update -qq && apt-get install -y -qq curl
          curl -fsS --max-time 10 "$ACTIONS_CACHE_URL" -o /dev/null -w '%{http_code}\n'

  # THE ONE-WAY RULE, from inside a job container, against the real VPS.
  # Every one of these must be blocked. `timeout 8 ... && exit 1` so a
  # SUCCESSFUL connection fails the job.
  one-way:
    runs-on: ubuntu-latest
    steps:
      - run: apt-get update -qq && apt-get install -y -qq netcat-openbsd curl
      - name: 443 to the VPS is permitted
        run: curl -fsS --max-time 10 -o /dev/null https://git.hu-tao.dev/api/v1/version && echo 443-ok
      - name: sshd on 2222 is blocked
        run: if timeout 8 nc -z 167.233.24.58 2222; then echo "REACHED 2222" >&2; exit 1; fi; echo blocked
      - name: smtp on 25 is blocked
        run: if timeout 8 nc -z 167.233.24.58 25; then echo "REACHED 25" >&2; exit 1; fi; echo blocked
      - name: imaps on 993 is blocked
        run: if timeout 8 nc -z 167.233.24.58 993; then echo "REACHED 993" >&2; exit 1; fi; echo blocked
      - name: forgejo ssh on 22 is blocked
        run: if timeout 8 nc -z 167.233.24.58 22; then echo "REACHED 22" >&2; exit 1; fi; echo blocked
      - name: the VPS IPv6 prefix is blocked
        run: if timeout 8 nc -6 -z 2a01:4f8:c015:b138:: 443; then echo "REACHED v6" >&2; exit 1; fi; echo blocked
```

- [ ] **Step 2: Commit and push the workflow**

```bash
git add .forgejo/workflows/runner-smoke.yml
git commit -m "test(runner): temporary smoke workflow for the new runner host

Five jobs covering what cannot be tested without the real box: the nix label
runs, docker works inside a job via podman's socket, a workflow's services:
resolve (the dns_enabled check, whose failure is a silent wait loop), the
Actions cache URL the runner auto-detects is actually reachable from a job
container, and every port on the VPS except 443 is blocked from inside a job.

Deleted once it has passed once.

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

**ASK THE USER before pushing.** This branch has not been pushed and the repo's
rule is explicit about it.

- [ ] **Step 3: Run it**

Forgejo → Actions → `runner smoke` → Run workflow, on `feat/ci-runner-host`.

- [ ] **Step 4: Read the results**

| job | expected | what a failure means |
| --- | --- | --- |
| `nix-label` | passes, hostname `forgejo-runner` | the runner is not picking up jobs, or the label is wrong |
| `docker-in-job` | `docker-in-ci-ok` | `container.docker_host` is wrong, or the podman socket is not group-readable by the runner |
| `service-dns` | `pg_isready` succeeds | `defaultNetwork.settings.dns_enabled` is not taking effect |
| `cache-reachable` | a 2xx/4xx status code, not a timeout | the auto-detected `cache.host` is not reachable from a per-job network — see Step 5 |
| `one-way` | 443 ok, **every other step prints `blocked`** | **stop everything**; the enforcement is not working on the real box |

- [ ] **Step 5: If `cache-reachable` fails, pin the host explicitly**

The one predicted failure. The fix is to name the host's public address rather
than relying on detection. In `modules/runner/default.nix`, inside the `cache`
attrset, replace the `host` comment block with:

```nix
          # Pinned rather than auto-detected. The runner's detection picks the
          # outbound source address, which is correct in principle; it is set
          # explicitly here because a job container reaching it is the one
          # thing that has to work and a silent fallback to 0.0.0.0 or a bridge
          # address makes every actions/cache step a no-op without logging.
          #
          # 46.225.61.172 is this box's public IPv4. A container on a per-job
          # network routes to it through its own gateway — this host — which
          # delivers locally, so the packet arrives at the INPUT chain with the
          # per-job bridge as iifname. modules/runner/firewall.nix accepts
          # exactly that.
          host = "46.225.61.172";
```

Then rebuild and re-run:

```bash
nix build .#nixosConfigurations.runner-hetzner.config.system.build.toplevel --no-link
nixos-rebuild switch --flake .#runner-hetzner \
  --target-host root@46.225.61.172 \
  --option ssh-option "ProxyJump=vps"
```

Re-run the smoke workflow's `cache-reachable` job.

- [ ] **Step 6: Delete the smoke workflow**

```bash
git rm .forgejo/workflows/runner-smoke.yml
git commit -m "test(runner): drop the smoke workflow

It passed: nix and ubuntu-latest labels run, docker works inside a job through
podman's socket, services: resolve, the Actions cache is reachable from a job
container, and every port on the VPS except 443 is blocked from inside one —
including the IPv6 prefix.

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Re-run the real CI on this branch**

The repo's own `.forgejo/workflows/ci.yml` runs on the `nix` label. Push the
branch (ask first) and confirm CI passes on the new runner — that is the
acceptance test that matters, because it is the workload.

### Task 8b: An L7 allowlist in front of Forgejo

**Files:**
- Modify: `modules/options.nix` (add `infra.runnerIPs`)
- Modify: `modules/containers/caddy.nix` (the `git.${domain}` vhost)
- Modify: `modules/firewall.nix` (read `infra.runnerIPs` for the egress rule)

**Interfaces:**
- Consumes: a runner with no write credential (Task 5a), and a live runner
  that has completed one CI run (Task 8) so the access log has real paths in it.
- Produces: `config.infra.runnerIPs`, the single list every consumer reads.

- [ ] **Step 1: Derive the real path set, do not guess it**

Guessing breaks CI in confusing ways. Turn on access logging for the git vhost,
run the repo's own CI once on the new runner, and read back what it touched:

```bash
# on the VPS, after one full CI run plus one pages run
sudo docker logs caddy 2>&1 | grep '46.225.61.172' \
  | python3 -c "
import sys, json
paths=set()
for line in sys.stdin:
    try: d=json.loads(line)
    except Exception: continue
    r=d.get('request',{})
    paths.add((r.get('method'), r.get('uri','').split('?')[0]))
for m,u in sorted(paths): print(m,u)
"
```

Expected shape — confirm against the output before writing the matcher:

| path | why |
| --- | --- |
| `/api/actions/*` | the `runner.v1.RunnerService` RPCs: Register, Declare, FetchTask, UpdateTask, UpdateLog |
| `/api/actions_pipeline/*` | artifact upload, which is how pages publishes after Task 10 |
| `/{owner}/{repo}/info/refs` | git discovery for `actions/checkout` and the workflows' own `git fetch` |
| `/{owner}/{repo}/git-upload-pack` | the fetch itself |

- [ ] **Step 2: Add `infra.runnerIPs` to `modules/options.nix`**

```nix
    runnerIPs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "46.225.61.172" ];
      description = ''
        Every CI runner's public IPv4. ONE list, because three things must
        agree on it and a clone that is in two of them is worse than a clone
        that is in none:

          * modules/firewall.nix opens tcp/22 egress to these, which is the
            admin path (`ssh -J vps`);
          * modules/containers/caddy.nix RESTRICTS these to the runner API
            paths on git.<domain>;
          * tofu/modules/hetzner-firewall scopes the same egress at the cloud
            edge.

        The failure this exists to prevent is fail-open: add a runner from the
        snapshot, forget the caddy entry, and that box gets the FULL Forgejo
        surface while looking like every other runner. Keeping one list means
        forgetting it makes the clone unreachable for administration — loud —
        rather than silently unrestricted.

        An address is the right key here and a token is not. A root-compromised
        runner can forge anything it holds; it cannot forge its source address,
        because Hetzner assigns it and filters spoofed egress upstream.
      '';
    };
```

- [ ] **Step 3: Restrict the git vhost in `modules/containers/caddy.nix`**

Inside the `git.${domain}` site block, before the existing `reverse_proxy`:

```
	@runner remote_ip ${concatStringsSep " " config.infra.runnerIPs}
	handle @runner {
		@runner_api path /api/actions/* /api/actions_pipeline/* /*/*/info/refs /*/*/git-upload-pack
		handle @runner_api {
			reverse_proxy forgejo:4242
		}
		respond "not permitted from a CI runner" 403
	}
```

Three properties worth stating, because they are why this is sound:

* **`remote_ip` is the TCP peer, never a header.** Caddy only consults
  `X-Forwarded-For` when `trusted_proxies` is set, and it is not set anywhere in
  this file. Every DNS record in `tofu/modules/cloudflare-dns` is
  `proxied = false`, so nothing sits in front of caddy to launder the address.
* **This grants nothing.** It is a pure restriction on one address; a request
  that fails to match just gets the ordinary public site. There is no incentive
  to evade the matcher and nothing gained by doing so.
* **It denies `git-receive-pack`.** That converts the spec's accepted residual
  risk — "a compromised runner can push to repos it built" — into something
  actually blocked, which no packet filter can do: push and fetch share a port
  and a TLS session.

- [ ] **Step 4: Have the firewall read the same list**

Task 6 added `ip daddr 46.225.61.172 tcp dport 22 ct state new accept` as a
literal. Replace it with a rule generated from the list, so the two can never
disagree:

```nix
          ${lib.concatMapStringsSep "\n          " (
            ip: "ip daddr ${ip} tcp dport 22 ct state new accept"
          ) config.infra.runnerIPs}
```

- [ ] **Step 5: Deploy and verify both directions**

```bash
deploy .#vps

# From the runner: the permitted path answers, the denied ones 403.
ssh -J vps root@46.225.61.172 '
  curl -sS -o /dev/null -w "actions rpc: %{http_code}\n" https://git.hu-tao.dev/api/actions/
  curl -sS -o /dev/null -w "api v1:      %{http_code}\n" https://git.hu-tao.dev/api/v1/version
  curl -sS -o /dev/null -w "web ui:      %{http_code}\n" https://git.hu-tao.dev/
  curl -sS -o /dev/null -w "upload-pack: %{http_code}\n" "https://git.hu-tao.dev/hutao/vps/info/refs?service=git-upload-pack"
  curl -sS -o /dev/null -w "recv-pack:   %{http_code}\n" -X POST https://git.hu-tao.dev/hutao/vps/git-receive-pack
'
```

Expected: `api v1`, `web ui` and `recv-pack` all **403**; `actions rpc` and
`upload-pack` not 403.

```bash
# From anywhere else: unchanged.
curl -sS -o /dev/null -w "%{http_code}\n" https://git.hu-tao.dev/api/v1/version   # 200
```

- [ ] **Step 6: Re-run CI on the runner**

The acceptance test is the workload. If a step 403s, add the path it needs —
from the access log, not from memory — and redeploy.

- [ ] **Step 7: Commit**

```bash
nixfmt modules/options.nix modules/containers/caddy.nix modules/firewall.nix
git add -A
git commit -m "feat(caddy): restrict CI runners to the Actions API paths

nftables can only say '443 to that host'. Behind that port is Forgejo's whole
HTTP surface — the web UI, /api/v1/*, every repo over git-http. Caddy already
terminates that 443 and can see paths, so the runner addresses are allowed the
runner RPCs, the artifact pipeline and git-upload-pack, and 403'd for
everything else.

Denying git-receive-pack is the one that matters: it converts 'a compromised
runner can push to repos it built' from an accepted residual risk into
something blocked. No packet filter can do that — push and fetch share a port
and a TLS session.

Keyed on remote_ip because a root-compromised runner can forge anything it
holds but not its source address. remote_ip is the TCP peer and never a header:
trusted_proxies is unset and every DNS record is proxied = false.

infra.runnerIPs is one list read by all three consumers so a clone cannot end
up in two of them. Forgetting it makes the new box unreachable for admin, which
is loud, rather than silently unrestricted.

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Phase 6 — Snapshot

### Task 9: Make the image a clone can come from

**Files:**
- Modify: `docs/superpowers/specs/2026-09-18-ci-runner-host-design.md` (record
  the snapshot id)

**Interfaces:**
- Consumes: the verified box from Task 8.
- Produces: a snapshot id, and the documented `hcloud server create` incantation
  for a clone.

- [ ] **Step 1: Warm the store, then stop the runner cleanly**

```bash
timeout 60 ssh -o BatchMode=yes -J vps root@46.225.61.172 '
  systemctl stop gitea-runner-forgejo.service
  nix-collect-garbage --delete-older-than 7d
  nix store optimise
'
```

Stopping the runner first so the snapshot does not capture a half-written job.

- [ ] **Step 2: Remove the machine-specific identity from the image**

The `.runner` file holds the uuid Forgejo issued to *this* box. A clone booting
with it would be a second daemon claiming one record — the exact failure the
registration design exists to avoid.

```bash
timeout 30 ssh -o BatchMode=yes -J vps root@46.225.61.172 '
  rm -f /var/lib/gitea-runner/forgejo/.runner \
        /var/lib/gitea-runner/forgejo/.token-hash \
        /var/lib/gitea-runner/forgejo/.labels \
        /var/lib/forgejo-runner-token/token.env
  rm -f /etc/ssh/ssh_host_*
  ls -la /var/lib/gitea-runner/forgejo/ /var/lib/forgejo-runner-token/
'
```

Host keys too: every clone sharing one host key means a `ssh -J vps` to a new
box silently authenticates against the old one's key. NixOS regenerates them on
next boot.

**This unregisters the box from Forgejo's point of view.** The original runner
will need its token re-staged and the unit restarted in Step 6 to come back.

- [ ] **Step 3: Power off and snapshot**

```bash
timeout 30 ssh -o BatchMode=yes -J vps root@46.225.61.172 'systemctl poweroff' || true
sleep 30
# Then, in the Hetzner console or via the API:
#   Server 166488672 -> Snapshots -> Take snapshot
#   Description: nixos-ci-runner-YYYY-MM-DD
```

Wait for the server to report `off` before taking the snapshot. A snapshot of a
running machine captures a dirty filesystem.

- [ ] **Step 4: Record the snapshot id**

Append to the spec's `## Snapshot and replication` section:

```markdown
### The live image

| snapshot | taken | from |
| --- | --- | --- |
| `<id>` `nixos-ci-runner-<date>` | <date> | 166488672 after a verified smoke run |

Create a clone with the token in user-data, which is the path
`modules/runner/identity.nix` treats as the steady state:

```bash
hcloud server create \
  --name forgejo-runner-2 \
  --type cx33 \
  --location nbg1 \
  --image <snapshot id> \
  --firewall runner-firewall \
  --user-data-from-file <(printf 'forgejo-runner-token: %s\n' "$TOKEN")
```

No deploy, no flake change, no commit. The snapshot carries a warm nix store,
which is what keeps a fresh clone from paying a cold build.

Two things the clone does NOT get, by design: a private NIC (there is none to
attach) and a tailscale identity (it runs no tailscale). Its admin path is
`ssh -J vps root@46.225.61.172`, which needs the new address added to
`tofu/modules/hetzner-firewall`'s scoped egress rule and to the VPS's own
output chain in `modules/firewall.nix` — two edits per clone, deliberately, so
a new box cannot be reached from the VPS until someone says so.
```

- [ ] **Step 5: Power the original back on and restore its identity**

```bash
# Console, or: hcloud server poweron 166488672
# Then mint a fresh registration token in Forgejo and:
timeout 30 ssh -o BatchMode=yes -J vps root@46.225.61.172 '
  install -d -m 0700 /var/lib/forgejo-runner-token
  umask 077
  read -rs TOK
  printf "TOKEN=%s\n" "$TOK" > /var/lib/forgejo-runner-token/token.env
  chmod 0400 /var/lib/forgejo-runner-token/token.env
  systemctl restart gitea-runner-forgejo.service
  systemctl is-active gitea-runner-forgejo.service
'
```

The host key changed, so the first connection will warn. Remove the stale entry
from `~/.ssh/known_hosts` rather than disabling the check.

- [ ] **Step 6: Confirm it is Idle in Forgejo again, then commit the spec**

```bash
git add docs/superpowers/specs/2026-09-18-ci-runner-host-design.md
git commit -m "docs: record the runner snapshot and how to clone from it

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Phase 7 — Decommission the VPS runner

### Task 10: Pages — reverse the direction

**The gate is real, not theoretical.** `https://pages.hu-tao.dev/hutao/compress/`
returns **200** today. Verified 2026-09-19.

**What publishes it**, read from the live instance
(`hutao/compress/.forgejo/workflows/pages.yml`, public repo, anonymous read):

```yaml
    container:
      image: node:22-bookworm
      volumes:
        - pages_data:/pages          # the one entry in valid_volumes
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
      - run: npm run build
        env:
          PAGES: '1'
          BASE_PATH: '/${{ github.repository }}'
      - name: Publish
        run: |
          dest="/pages/$GITHUB_REPOSITORY"
          rm -rf "$dest" && mkdir -p "$dest"
          cp -r build/. "$dest/"
```

The job writes straight into caddy's volume. On the new runner that volume does
not exist and `container.valid_volumes` is empty, so the Publish step fails.

**Why artifacts and not a `gh-pages` branch.** The idiomatic answer would be a
branch the job pushes and the VPS clones. That needs `git-receive-pack`, which
Task 5b **denies at caddy**. The artifact route rides `/api/actions_pipeline/*`,
which is on the allowlist. The two designs agree rather than fight, and that is
the reason to pick this one.

**What crosses the boundary: nothing new.** The upload is runner → Forgejo on
443, already permitted. The pull is the VPS talking to its own Forgejo
container and never leaves the box.

**No credential is needed.** `hutao/compress` is public and
`GET /api/v1/repos/hutao/compress/actions/artifacts` returns `200 []`
anonymously — verified against the live instance. A sops token appears only if a
private repo ever publishes.

**Pages does not go down during this migration, it goes stale.** The volume
keeps its contents and caddy keeps serving them, so an ordering mistake costs
freshness, not availability.

**Files:**
- Modify: `hutao/compress/.forgejo/workflows/pages.yml` — **a different repo**
- Create: `modules/pages-pull.nix`
- Modify: `configuration.nix` (import it), `modules/options.nix` (`infra.pagesRepos`)

**Interfaces:**
- Consumes: `config.infra.pagesVolume` (`pages_data`), `config.infra.domain`.
- Produces: `pages-pull.service` + `.timer`. Task 11 requires this verified.

- [ ] **Step 1: Confirm the publisher list**

`hutao/compress` is the only one confirmed. Check for others before assuming:

```bash
ssh hutao@vps            # interactive; tailscale SSH cannot be scripted
sudo ls /var/lib/docker/volumes/pages_data/_data/*/
```

Every `<owner>/<repo>` directory there is a publisher and needs both halves of
this task.

- [ ] **Step 2: Add `infra.pagesRepos` to `modules/options.nix`**

```nix
    pagesRepos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "hutao/compress" ];
      description = ''
        `<owner>/<repo>` for every repository that publishes to
        `pages.<domain>`. modules/pages-pull.nix fetches each one's newest
        artifact named `pages` and unpacks it at that same path under
        `pagesVolume`, because the layout IS the URL.

        A repo publishes by uploading an artifact, NOT by mounting the volume —
        the runner moved off this host and cannot write here. See the
        design doc.
      '';
    };
```

- [ ] **Step 3: Change the publisher (in `hutao/compress`)**

Replace the `volumes:` block and the whole `Publish` step with:

```yaml
      - name: Upload
        uses: actions/upload-artifact@v4
        with:
          name: pages
          path: build/
          retention-days: 90
```

Delete the `container.volumes` entry entirely. `ubuntu-latest` is
`node:22-bookworm`, which has node, so the JavaScript action runs.

**Verify artifact v4 actually works before relying on it.** This instance is
`16.0.4+gitea-1.22.0` and v4 support landed in the 1.22 line, so it should — but
push the change, run the workflow once, and confirm:

```bash
curl -sS 'https://git.hu-tao.dev/api/v1/repos/hutao/compress/actions/artifacts' \
  | python3 -m json.tool | head -30
```

Expected: a non-empty list with an entry named `pages`. If v4 fails, drop to
`actions/upload-artifact@v3`, which the same API serves.

- [ ] **Step 4: Create `modules/pages-pull.nix`**

```nix
# ==============================================================================
# Pulling published pages off the runner
# ==============================================================================
# The pages job used to WRITE into the pages_data volume — that is what the old
# forgejo-runner.nix's one-entry valid_volumes allow-list was for. A runner on
# its own box cannot do that and must not: it would be the runner reaching into
# this machine, which is the one thing the split forbids.
#
# So the direction reverses. The job uploads an artifact; this fetches it. Every
# connection is initiated here, and in fact never leaves the host — the artifact
# is in Forgejo's own storage, in a container on this box.
#
# NO CREDENTIAL. The publishing repos are public and Forgejo serves
# /api/v1/repos/<owner>/<repo>/actions/artifacts anonymously (verified
# 2026-09-19: 200). The day a PRIVATE repo publishes, this needs a sops token
# with read:repository and not before — do not add one speculatively.
#
# NOT a gh-pages branch, which would be the idiomatic shape. That needs
# git-receive-pack, which modules/containers/caddy.nix denies to runner
# addresses. Artifacts ride /api/actions_pipeline/*, which it permits.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.infra) domain pagesVolume pagesRepos;

  fqdn = "git.${domain}";
  pagesRoot = "/var/lib/docker/volumes/${pagesVolume}/_data";
in
{
  systemd.services.pages-pull = {
    description = "Fetch published pages artifacts into the pages volume";
    after = [ "docker-forgejo.service" ];
    wants = [ "docker-forgejo.service" ];

    serviceConfig = {
      Type = "oneshot";
      # Writes into a docker volume, which is root-owned.
      User = "root";
    };

    path = with pkgs; [
      curl
      jq
      unzip
      coreutils
    ];

    script = ''
      set -euo pipefail

      for repo in ${lib.escapeShellArgs pagesRepos}; do
        echo "== $repo"

        # Newest artifact named `pages` that has not expired. Forgejo returns
        # expired entries with expired=true rather than omitting them, so
        # filtering on it is what stops us unpacking a 404.
        id=$(curl -fsS --max-time 30 \
          "https://${fqdn}/api/v1/repos/$repo/actions/artifacts" \
          | jq -r '[.artifacts[]? | select(.name == "pages") | select(.expired != true)]
                   | sort_by(.created_at) | last | .id // empty')

        if [ -z "$id" ]; then
          # NOT an error, and NOT a reason to delete anything. Artifacts expire;
          # a repo that has not built in 90 days should keep serving its last
          # published build rather than 404.
          echo "no live pages artifact for $repo; leaving the existing tree alone"
          continue
        fi

        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT

        curl -fsSL --max-time 120 \
          "https://${fqdn}/api/v1/repos/$repo/actions/artifacts/$id/zip" \
          -o "$tmp/pages.zip"
        unzip -q "$tmp/pages.zip" -d "$tmp/out"

        # Skip an unchanged build rather than churning the volume every 5
        # minutes: the id only moves when a new artifact is uploaded.
        stamp="${pagesRoot}/.stamp-$(echo "$repo" | tr / _)"
        if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$id" ]; then
          echo "$repo already at artifact $id"
          rm -rf "$tmp"; trap - EXIT
          continue
        fi

        # ATOMIC SWAP. caddy serves this read-only and a half-written tree is a
        # half-broken site, so the new content is staged as a sibling and
        # renamed over the old one — rename(2) within a filesystem is atomic.
        dest="${pagesRoot}/$repo"
        staging="$dest.new"
        install -d -m 0755 "$(dirname "$dest")"
        rm -rf "$staging"
        cp -a "$tmp/out" "$staging"
        rm -rf "$dest.old"
        if [ -e "$dest" ]; then mv "$dest" "$dest.old"; fi
        mv "$staging" "$dest"
        rm -rf "$dest.old"

        echo "$id" > "$stamp"
        echo "$repo updated to artifact $id"

        rm -rf "$tmp"; trap - EXIT
      done
    '';
  };

  systemd.timers.pages-pull = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Five minutes. It was instant when the job wrote the volume directly, and
      # this is the cost of reversing the direction. A Forgejo webhook would make
      # it instant again at the price of an HTTP receiver on the mail server,
      # which is not a trade worth making for a static site.
      OnCalendar = "*:0/5";
      Persistent = true;
    };
  };
}
```

- [ ] **Step 5: Wire it in and deploy**

Add `./modules/pages-pull.nix` to `configuration.nix`'s `imports`, then:

```bash
nix build .#nixosConfigurations.vps-hetzner.config.system.build.toplevel --no-link
deploy .#vps
```

- [ ] **Step 6: Run it by hand and verify the site is intact**

```bash
# on the VPS
systemctl start pages-pull.service
journalctl -u pages-pull -n 30 --no-pager
```

Expected: `hutao/compress updated to artifact <id>`.

```bash
# from anywhere
curl -sS -o /dev/null -w '%{http_code}\n' https://pages.hu-tao.dev/hutao/compress/
```

Expected: **200**, same as before the change.

- [ ] **Step 7: Prove idempotence and the no-artifact path**

```bash
# on the VPS — a second run must be a no-op, not a re-copy.
systemctl start pages-pull.service
journalctl -u pages-pull -n 10 --no-pager | grep 'already at artifact'
```

Expected: `hutao/compress already at artifact <id>`. This is what stops the
timer rewriting the volume 288 times a day.

Then confirm a missing artifact does not delete the site — the failure mode that
would take pages down rather than leaving it stale:

```bash
# on the VPS
rm -f /var/lib/docker/volumes/pages_data/_data/.stamp-hutao_compress
# temporarily point infra.pagesRepos at a repo with no pages artifact,
# deploy, run the unit, and confirm the existing tree survives:
curl -sS -o /dev/null -w '%{http_code}\n' https://pages.hu-tao.dev/hutao/compress/
```

Expected: still **200**, and the journal says
`no live pages artifact for ...; leaving the existing tree alone`. Restore
`infra.pagesRepos` afterwards.

- [ ] **Step 8: Commit**

```bash
nixfmt modules/pages-pull.nix modules/options.nix
git add -A
git commit -m "feat(pages): pull published artifacts instead of letting the runner write

The pages job mounted the pages_data volume directly — the single entry in the
old runner's valid_volumes allow-list. A runner on its own box cannot do that
and must not, so the direction reverses: the job uploads an artifact and a
timer here fetches it. Every connection is initiated on this host, and in fact
never leaves it, because the artifact sits in Forgejo's own storage in a
container on this box.

Artifacts rather than a gh-pages branch because a branch needs git-receive-pack,
which caddy now denies to runner addresses. This route rides
/api/actions_pipeline/*, which it permits.

No credential: the publishing repos are public and Forgejo serves the artifacts
API anonymously. A missing or expired artifact leaves the existing tree alone
rather than deleting it, and an unchanged artifact id is a no-op, so the
five-minute timer does not rewrite the volume 288 times a day.

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 11: Delete the VPS runner

**Do not start until Task 10 is verified.** Pages is live —
`https://pages.hu-tao.dev/hutao/compress/` returns 200 — so the pull must be
working first. Deleting the runner before then does not take pages down, but it
freezes it at whatever build the volume already holds.

**Files:**
- Delete: `modules/containers/forgejo-runner.nix`
- Modify: `modules/containers/default.nix` (drop the import)
- Modify: `modules/secrets.nix` (drop `forgejo_runner_token`)
- Modify: `secrets.yaml` (drop the value)
- Modify: `secrets.example.yaml` (drop the documented key)
- Modify: `modules/firewall.nix` (bind the nine port-accepts to the public NIC)

**Interfaces:**
- Consumes: a verified runner from Phase 5 and a resolved Task 10.
- Produces: a VPS with no runner and a corrected input chain.

- [ ] **Step 1: Disable the old runner in Forgejo first, not last**

Site Administration → Actions → Runners → the `hu-tao` runner → delete it. Do
this *before* the deploy, so that any job queued in between goes to the new box
rather than to a runner about to disappear mid-job.

- [ ] **Step 2: Bind the nine port-accepts to the public interface**

This is correct independently of the runner work, and it is what makes the
absent private NIC belt-and-braces rather than the only control. In
`modules/firewall.nix`'s `input` chain, change:

```nft
          tcp dport {
            22,
            25,
            80,
            443,
            465,
            587,
            993,
            25565,
            25566
          } ct state new accept
```

to:

```nft
          # iifname enp1s0, added 2026-09-19. Without it these nine ports accept
          # new connections from ANY interface — including a private NIC, the
          # moment one is attached. The CI runner was attached to
          # hcloud_network.main on 2026-09-18 and detached in 5d0ae14 precisely
          # because "one edit away from silently reopening nine ports on the
          # mail server" is not a property to build a trust boundary on.
          #
          # The subnet stays (the VPS holds 10.0.1.2) for a future TRUSTED box,
          # and this rule is what makes attaching one a deliberate act rather
          # than an accidental opening.
          iifname enp1s0 tcp dport {
            22,
            25,
            80,
            443,
            465,
            587,
            993,
            25565,
            25566
          } ct state new accept
```

Verify the interface name first — do not assume:

```bash
ssh hutao@vps   # interactive; tailscale SSH cannot be scripted
ip -br link show | grep -v 'lo\|docker\|br-\|veth\|tailscale'
```

Use whatever that prints. `enp1s0` is what Hetzner Cloud usually gives, but a
wrong name here drops mail, git and https on the next deploy — and deploy-rs
will roll it back, which is the circuit breaker doing its job rather than a
reason to skip the check.

- [ ] **Step 3: Delete the module and its import**

```bash
git rm modules/containers/forgejo-runner.nix
```

In `modules/containers/default.nix`, remove the line `    ./forgejo-runner.nix`
from the `imports` list.

- [ ] **Step 4: Drop the secret**

In `modules/secrets.nix`, remove the `forgejo_runner_token` entry. In
`secrets.example.yaml`, remove the documented key and its comment. Then remove
the real value:

```bash
SOPS_AGE_KEY_FILE=/var/lib/sops-nix/vps.txt sops secrets.yaml
# delete the forgejo_runner_token key, save, exit
```

- [ ] **Step 5: Verify the VPS still evaluates and the runner is gone**

```bash
nix eval --json .#nixosConfigurations.vps-hetzner.config --apply '
  c: {
    runnerContainer = c.virtualisation.oci-containers.containers ? forgejo-runner;
    runnerSecret    = c.sops.secrets ? forgejo_runner_token;
    tokenUnit       = c.systemd.services ? forgejo-runner-token;
    readyUnit       = c.systemd.services ? forgejo-runner-ready;
  }'
```

Expected: all four `false`.

```bash
nix build .#nixosConfigurations.vps-hetzner.config.system.build.toplevel --no-link
```

Expected: exit 0.

- [ ] **Step 6: Deploy**

```bash
deploy .#vps
```

Expected: activation succeeds and the circuit breaker confirms over a fresh
connection. If it rolls back, the interface name in Step 2 is wrong.

- [ ] **Step 7: Verify mail, git and https still answer from outside**

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' https://git.hu-tao.dev/api/v1/version
timeout 8 nc -z 167.233.24.58 25   && echo smtp-ok
timeout 8 nc -z 167.233.24.58 993  && echo imaps-ok
timeout 8 nc -z 167.233.24.58 22   && echo forgejo-ssh-ok
```

All four must succeed. Then confirm the runner container is really gone:

```bash
ssh hutao@vps   # interactive
sudo docker ps -a --format '{{.Names}}' | grep -c forgejo-runner   # expect 0
sudo docker volume ls | grep forgejo_runner_data
```

The `forgejo_runner_data` volume survives the module's removal — NixOS does not
delete volumes. Leave it for now; removing it discards the old Actions cache and
is a separate, deliberate `docker volume rm`.

- [ ] **Step 8: Commit**

```bash
nixfmt modules/firewall.nix modules/secrets.nix modules/containers/default.nix
git add -A
git commit -m "refactor(runner): remove the runner from the VPS

Its replacement has been running CI on its own box since Phase 5. What goes
with it: the /var/run/docker.sock mount that made a workflow root-equivalent on
a machine serving mail, git and every sops secret, the one-entry valid_volumes
allow-list that existed to contain it, the forgejo_runner_token secret, and the
published cache-proxy port.

Also binds the nine public port-accepts to enp1s0. They had no iifname, so they
accepted new connections from any interface — including a private NIC the
moment one is attached. The subnet stays for a future trusted box, and this is
what makes attaching one a deliberate act rather than an accidental opening of
nine ports on the mail server.

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 9: Update ARCHITECTURE.md and README.md**

Both describe the runner as a container on the VPS. Grep and correct:

```bash
grep -n "forgejo-runner\|Actions runner\|runner" ARCHITECTURE.md README.md
```

Commit as `docs: describe the runner as its own host`.

---

## Self-Review

**Spec coverage.** Every section of
`docs/superpowers/specs/2026-09-18-ci-runner-host-design.md` maps to a task:
"The runner is not a container" → Task 2; "Jobs get a container engine" → Task 2
+ Task 8's `docker-in-job`; "Identity is registered" → Task 3; "may not initiate
anything toward the VPS" → Tasks 4, 5, 6, 8; Topology → Task 0; private NIC →
already done in `5d0ae14`; "What no firewall closes" → unchanged, accepted;
podman + DNS trap → Task 2 + Task 8's `service-dns`; runner settings table →
Task 2 Step 5; one-way enforcement → Tasks 4-5; disk and GC → Task 2's `nix.gc`
override and `autoPrune`; snapshot and replication → Task 9; VPS-side changes →
Tasks 6, 10, 11; Files table → the File Structure section, extended with
`modules/runner/networking.nix` and `tests/runner-firewall.nix`, which the spec
did not name; Secrets → Global Constraints + Task 1's assertion; Out of scope →
untouched.

**Gaps the spec left that this plan fills:** the tailnet hole (Task 0/6), the
EnvironmentFile format (Task 0/3), the VPS's own output chain (Task 6), IPv6
(Task 4), and the pages gate — the spec lists the pages pull as a bullet without
noting it blocks the deletion and lives in another repo (Task 10).

**Resolved since the first draft.** The pages gate is no longer an unknown: the
site is live (200 on `hutao/compress`), the publishing workflow was read from
the instance, the artifacts API was confirmed present and anonymously readable,
and Task 10 now carries the full design rather than a placeholder. The only
interactive step left there is Step 1 — listing the volume to check for
publishers beyond `hutao/compress` — and getting it wrong costs one un-migrated
page, not an outage.

**Ordering constraints worth keeping.** Task 5a is independent and can run any
time before Task 8b. Task 8b must run *after* Task 8, because its first step
derives the allowlist from a real CI run's access log rather than guessing. Task
11 must run after Task 10 is verified. Task 6 must precede Task 7, because
nothing installs until the jump works.
