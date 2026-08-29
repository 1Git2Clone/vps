# ==============================================================================
# Nix daemon
# ==============================================================================
{
  nix.settings = {
    # deploy-rs (and `nixos-rebuild --target-host`) build the closure on the
    # workstation and push it over ssh as `hutao`. Those paths are locally built
    # and therefore unsigned, and the daemon refuses unsigned paths from an
    # untrusted user with:
    #
    #   cannot add path '/nix/store/…' because it lacks a signature by a
    #   trusted key
    #
    # This is not a new privilege: a trusted nix user can substitute arbitrary
    # store content, which is root-equivalent, and hutao already has
    # passwordless sudo via wheel (see modules/security.nix). Anyone who can
    # push a closure here could already run anything here.
    trusted-users = [
      "root"
      "@wheel"
    ];

    # A build that fills the disk takes the whole stack down with it, and this
    # box holds mail. Keep headroom rather than discovering it at 3am.
    min-free = 2147483648; # 2 GiB: start freeing
    max-free = 6442450944; # 6 GiB: stop freeing

    experimental-features = [
      "nix-command"
      "flakes"
    ];
  };

  # Weekly, and only generations older than a month — recent ones are what a
  # rollback needs, and the bootloader menu is the last line of defence when a
  # deploy leaves the box unbootable.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
}
