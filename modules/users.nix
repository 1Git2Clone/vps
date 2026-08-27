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
        ];
      };
      hutao = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];

        hashedPasswordFile = config.sops.secrets.user_password.path;

        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKq9bjfE2uA4pDqAJbfftacgk9OK/EgeLp4gG/uZcFNc ivan@hu-tao.dev"
        ];
      };
    };
  };
}
