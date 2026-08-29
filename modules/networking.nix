# ==============================================================================
# Networking
# ==============================================================================
# The hostname was previously unset, which meant it defaulted to "nixos" — and
# tailscale registers a node under it, so the tailnet would have gained a second
# node called "nixos" next to the existing one. It is also what shows up in
# journals and in `ssh` prompts, so a real name is worth the one line.
#
# NOT the mail hostname: DMS sets its own container hostname to smtp.<domain>,
# which is what HELO and the rDNS check see. Those two are deliberately
# independent — see modules/containers/mailserver.nix.
{ config, ... }:

{
  networking = {
    hostName = "hu-tao";
    domain = config.infra.domain;
  };
}
