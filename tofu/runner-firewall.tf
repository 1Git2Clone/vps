# ==============================================================================
# The CI runner's firewall
# ==============================================================================
# Separate from main-firewall on purpose. The runner was attached to that one by
# the console at creation, which opened 25, 465, 587, 993, 25565 and 25566 on a
# box that runs none of them — the mail-and-minecraft profile inherited by a CI
# machine. Nothing listened, so nothing was exploitable, but "closed because no
# daemon happens to bind it" is not a control.
#
# TWO THINGS THAT SHAPE EVERY RULE BELOW.
#
# First: this firewall filters the PUBLIC interface only. Traffic over the
# private network (network.tf) is never seen by it, so "the runner may talk to
# the VPS privately" needs no rule here and gets none. That access is governed
# by the hosts' own nftables.
#
# Second: Hetzner's semantics are all-or-nothing per direction. An EMPTY rule
# set in a direction means ALLOW EVERYTHING in that direction, not deny — so the
# outbound list below cannot be trimmed to nothing to mean "no egress", and
# every port the runner needs has to be named or CI simply stops working.
#
# Which is the correction to "it doesn't need any outside access": inbound, true,
# and it gets almost none. Outbound, not at all — a runner with no egress cannot
# pull a job image, reach cache.nixos.org, resolve crates.io or fetch the commit
# it is meant to test. Least privilege here means a named egress list, not none.

resource "hcloud_firewall" "runner" {
  name = "runner-firewall"

  # ---- inbound -------------------------------------------------------------
  # One rule, and it is scaffolding.
  #
  # nixos-anywhere has to reach a shell on this box before NixOS exists on it,
  # and the bootstrap Ubuntu's sshd is on 22. Rather than opening 22 to the
  # internet, it is opened only to the VPS, so the install runs as
  #
  #     nixos-anywhere --ssh-option ProxyJump=vps root@10.0.1.3
  #
  # i.e. jumped through a box that is already reachable over tailscale. Note
  # this needs tcp/22 OUTBOUND on main-firewall, which the VPS does not
  # currently have — see the note in hetzner-firewall.tf.
  #
  # DELETE THIS RULE once NixOS is installed and tailscale is up there. At that
  # point the correct inbound set is empty: administration goes over the tailnet,
  # and the tailnet does not need an inbound rule to work (it NAT-traverses, and
  # falls back to DERP over outbound 443).
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = ["167.233.24.58/32"]
    description = "Bootstrap sshd, from the VPS only — remove after nixos-anywhere"
  }

  # ---- outbound ------------------------------------------------------------
  # The minimum a CI runner needs to do its job, and nothing shaped like a
  # service. No 25 (it sends no mail), no 7844 (it fronts no tunnel), no 2222.
  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "53"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "DNS TCP"
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "53"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "DNS UDP"
  }

  # 443 is the one that matters: cache.nixos.org, the docker registries behind
  # the four `runs-on` labels, crates.io, and https://git.hu-tao.dev/ — which the
  # runner reaches over the PUBLIC address by design, because it hands that same
  # URL to every job container and a job container sits on a per-job network
  # where no internal name resolves. See modules/containers/forgejo-runner.nix.
  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "443"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "HTTPS — substituters, registries, the Forgejo instance"
  }

  # Plain HTTP: apt on the bootstrap image, redirects, and the occasional
  # substituter that has not moved.
  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "80"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "HTTP"
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "123"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "NTP"
  }

  # Tailscale, for when this box joins the tailnet and the inbound rule above
  # can be deleted. 443/udp is the DERP fallback that makes it work even when
  # direct fails; 3478 and 41641 are what let it avoid the relay.
  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "443"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "QUIC / Tailscale DERP"
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "3478"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "STUN (Tailscale)"
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "41641"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "Tailscale direct (avoids DERP relay)"
  }
}

# Attachment as its own resource, matching modules/hetzner-firewall: a rule
# change stays a firewall diff rather than reading as a server diff.
#
# This is also what detaches main-firewall from the runner. hcloud allows a
# server in several firewalls at once, and main-firewall's attachment is
# authoritative over its own applied_to list — so the runner leaves that list in
# hetzner-firewall.tf and arrives here, in one apply. There is no lockout window
# in between: a server with no firewall attached is unfiltered, not sealed.
#
# If these rules are wrong and ssh does go away, the recovery path is the
# console's web terminal, not a rebuild.
resource "hcloud_firewall_attachment" "runner" {
  firewall_id = hcloud_firewall.runner.id
  server_ids  = [hcloud_server.runner.id]
}
