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
