# ==============================================================================
# Booting
# ==============================================================================
{
  boot = {
    loader = {
      # ===
      # Alternative with grub:
      # ===

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

  system = {
    stateVersion = "26.05";
  };
}
