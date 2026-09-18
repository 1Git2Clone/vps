# ==============================================================================
# The private network
# ==============================================================================
# One /16 with a single /24 subnet, joining the VPS and the CI runner so they
# can talk without going out to the internet and back in.
#
# The two boxes are in DIFFERENT locations — hu-tao in fsn1, forgejo-runner in
# nbg1 — and that is fine: a Hetzner network is scoped to a NETWORK ZONE, not a
# location, and both sit in eu-central. A subnet in a zone reaches every
# location in it. (Scaleway or any other provider could not join this, which is
# the whole reason the runner stayed on Hetzner.)
#
# Traffic on this network is free and does not count against the 20 TB.
#
# WHAT THIS DOES NOT DO: attaching a server here gives it a second NIC, it does
# not configure one. Until the NixOS side brings that interface up (Hetzner
# hands out the address over DHCP on the private NIC), 10.0.1.x is a Hetzner
# fact and not a reachable address. That is the next pass, with the runner move.
#
# Note also that hcloud firewalls filter the PUBLIC interface only — main-firewall
# does not see this traffic at all. What governs the private link is the host's
# own nftables in modules/firewall.nix, whose forward chain is policy-drop with
# an interface allow-list. Expect to add the private NIC there before anything
# actually flows.

resource "hcloud_network" "main" {
  name = "hu-tao"

  # Deliberately roomy and deliberately NOT overlapping docker. The host runs
  # docker with a pinned bip and per-job bridges in 172.16/12 (see
  # infra.dockerBridgeGateway and forgejo-runner.nix), so 10.0.0.0/16 cannot
  # collide with a bridge the daemon invents on its own. A collision here does
  # not fail loudly — it silently blackholes one side.
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "main" {
  network_id = hcloud_network.main.id
  type       = "cloud"

  # The zone, not a location. Both boxes are eu-central; see the header.
  network_zone = "eu-central"

  # A /24 out of the /16 above, leaving room to add more subnets later without
  # renumbering this one. Hetzner reserves .1 as the gateway, so usable host
  # addresses start at .2.
  ip_range = "10.0.1.0/24"
}

# Attachments are their own resources, one per server, each pinning an explicit
# address. Explicit rather than letting Hetzner assign: these addresses end up
# in NixOS config and in any future firewall rule, so they must not change when
# a server is detached and reattached.
#
# subnet_id, NOT network_id: attaching to a network whose subnet does not exist
# yet fails, and naming the subnet is what orders the two correctly.

resource "hcloud_server_network" "vps" {
  server_id = hcloud_server.vps.id
  subnet_id = hcloud_network_subnet.main.id
  ip        = "10.0.1.2"
}

resource "hcloud_server_network" "runner" {
  server_id = hcloud_server.runner.id
  subnet_id = hcloud_network_subnet.main.id
  ip        = "10.0.1.3"
}
