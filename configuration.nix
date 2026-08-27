{
  boot = {
    loader = {
      # ===
      # Alternative with grub:
      # ===
      #
      # grub = {
      #   enable = true;
      #   efiSupport = true;
      #   efiInstallAsRemovable = true;
      #   device = "nodev";
      # };
      # systemd-boot.enable = false;
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
  };

  # Let the image builder handle the filesystem device
  fileSystems."/" = {
    fsType = "ext4";
  };

  services.openssh.enable = true;

  users.users.root.openssh.authorizedKeys.keys = [
    (builtins.readFile ./secrets/ssh.pub)
  ];

  system.stateVersion = "26.05";
}
