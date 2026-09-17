# ==============================================================================
# Users
# ==============================================================================

{ config, ... }:

{
  users = {
    mutableUsers = false; # https://github.com/NixOS/nixpkgs/issues/95778

    users = {
      root = {
        hashedPasswordFile = config.sops.secrets.root_password.path;

        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKq9bjfE2uA4pDqAJbfftacgk9OK/EgeLp4gG/uZcFNc ivan@hu-tao.dev"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID49dv6XQCkieSTgT8fPD54NScv30jNDI7Z0QhEbz57v hutao@hutao"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIoqi3O0lsZ/4eZfwt39yUxInELGG91ucSaF4d+fUKhU hutao@hutao-desktop"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBAfw4ZR3O194CT9VNVMVv29DK1gaKCwxQp0CQRJwaSQ ivan@work-laptop"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJLLFqxc1Ihd4j676fikI7LH7WjXlEFkEr2g+d3090Rg hutao@hutao-laptop"
        ];
      };
      hutao = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];

        hashedPasswordFile = config.sops.secrets.user_password.path;

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
