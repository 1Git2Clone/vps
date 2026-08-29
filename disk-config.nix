{ lib, ... }:

{
  disko.devices.disk.main = {
    device = lib.mkDefault "/dev/vda";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        # BIOS boot partition: where GRUB's core image goes on a GPT disk.
        # Hetzner Cloud boots these VMs in legacy BIOS mode, so this is the
        # partition that actually gets used — see modules/boot.nix.
        boot = {
          name = "boot";
          size = "1M";
          type = "EF02";
        };
        # 1G, not 512M: this is also /boot, holding a kernel and initrd per
        # generation. It cannot be grown later without a reinstall, and running
        # it out of space breaks the next deploy rather than the current boot.
        ESP = {
          name = "ESP";
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          name = "root";
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
  virtualisation.vmVariantWithDisko = {
    virtualisation = {
      memorySize = 4096;
      # The default 2G disk leaves ~1G for / once the ESP takes its gigabyte,
      # which is not enough to pull the eleven declared container images — the
      # local VM fills up and every scan fails with ENOSPC. Test-only: the
      # Hetzner disk is sized by the provider, and vmVariantWithDisko applies to
      # `nix run .` alone, never to vps-hetzner.
      diskSize = 32768;
      forwardPorts = [
        {
          from = "host";
          host.address = "127.0.0.1";
          # 2222 on both ends: sshd moved off 22 so forgejo could publish it.
          host.port = 2222;
          guest.port = 2222;
        }
      ];
      qemu.options = [
        "-display"
        "vnc=127.0.0.1:0"
      ];
      sharedDirectories.sopsKey = {
        source = "$SOPS_KEY_DIR";
        target = "/var/lib/sops-nix";
      };
    };
  };
}
