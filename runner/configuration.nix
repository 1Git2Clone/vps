# ==============================================================================
# The CI runner host
# ==============================================================================
# The sibling of the repo-root configuration.nix, and deliberately a much
# shorter list. What is NOT here is the point of the file:
#
#   * no ./modules/secrets.nix — this host holds no key from this repo and
#     decrypts nothing in secrets.yaml. See "Secrets" in the design doc.
#   * no ./modules/services.nix — it carries tailscale (whose authKeyFile is a
#     sops secret) and a fail2ban jail for a forgejo container that does not
#     run here. The tailnet is excluded on purpose, not by omission: the VPS
#     accepts `iifname tailscale0` unconditionally, so a runner on the tailnet
#     would reach every port on the box this split exists to protect.
#   * no ./modules/containers — nothing on this host is an oci-container,
#     including the runner itself.
#
# ./modules/options.nix is here for `infra.domain` and `infra.publicIPv4`,
# which modules/runner/{default,firewall}.nix read. Everything else it declares
# is an unused option with a default, which costs nothing.
{
  imports = [
    ../modules/options.nix
    ../modules/boot.nix
    ../modules/hardware.nix
    ../modules/nix.nix
    ../modules/security.nix
    ../modules/runner
  ];
}
