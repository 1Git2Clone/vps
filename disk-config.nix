{ lib, ... }:

{
  disko.devices.disk.main = {
    device = lib.mkDefault "/dev/vda";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          name = "boot";
          size = "1M";
          type = "EF02";
        };
        ESP = {
          name = "ESP";
          size = "512M";
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
      forwardPorts = [
        {
          from = "host";
          host.address = "127.0.0.1";
          host.port = 2222;
          guest.port = 22;
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
