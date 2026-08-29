# ==============================================================================
# Booting
# ==============================================================================
# GRUB, not systemd-boot. This is not a preference — the CX33 currently running
# this stack has no /sys/firmware/efi at all, so Hetzner Cloud boots it in
# legacy BIOS mode. systemd-boot is EFI-only: it would install successfully,
# report nothing wrong, and leave an unbootable machine on the first reboot.
#
# Configured for BOTH firmware modes on purpose, because the answer is a
# property of the hypervisor rather than of this config:
#
#   * `device` embeds GRUB's core image in the 1M EF02 partition that
#     disk-config.nix creates, which is what BIOS firmware chain-loads.
#   * `efiSupport` additionally writes an EFI binary to the ESP, so the same
#     closure boots if the machine turns out to be UEFI.
#   * `efiInstallAsRemovable` writes /EFI/BOOT/BOOTX64.EFI — the fallback path
#     firmware looks for with no NVRAM entry. This is what makes it work
#     without efivars, which do not exist when booted via BIOS.
#
# canTouchEfiVariables MUST stay false for the same reason: there is no efivarfs
# to write to in BIOS mode, and bootloader installation fails outright if it
# tries.
{ config, ... }:

{
  boot = {
    loader = {
      grub = {
        enable = true;

        # Derived from disko rather than written twice. The local QEMU VM gets
        # /dev/vda and Hetzner gives /dev/sda, and GRUB installed to a device
        # that does not exist is a failed install at best — silently the wrong
        # disk at worst. One source of truth for the device, in disk-config.nix.
        device = config.disko.devices.disk.main.device;
        efiSupport = true;
        efiInstallAsRemovable = true;

        # The ESP doubles as /boot and holds a kernel + initrd per generation.
        # Unbounded, it eventually fills a partition that cannot be grown
        # without a reinstall.
        configurationLimit = 10;
      };

      efi.canTouchEfiVariables = false;

      # A bad kernel or initrd is the one failure deploy-rs cannot roll back
      # from, because the box never comes up to be rolled back. This is the
      # window to pick the previous generation from the Hetzner console.
      timeout = 5;
    };
  };

  # Etc/UTC, matching the old box exactly. Not cosmetic: with time.timeZone
  # unset, NixOS does not manage /etc/localtime at all, so the path simply does
  # not exist — and docker, asked to bind-mount it into a container, creates a
  # DIRECTORY there and then fails with "not a directory: Are you trying to
  # mount a directory onto a file". That took out mailserver and forgejo, both
  # of which mount it for log timestamps.
  time.timeZone = "Etc/UTC";

  system = {
    stateVersion = "26.05";
  };
}
