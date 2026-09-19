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
# First: this firewall filters the PUBLIC interface only, which is the whole
# interface this box has. A Hetzner private network is invisible to these rules
# — no ACLs, no inspection, attached or not is the only control — so the runner
# was deliberately kept off the one that existed, and that network has since
# been deleted outright: with only the VPS on it, it was an unfiltered path to
# nine ports that modules/firewall.nix accepts with no iifname. Everything
# between these two hosts is therefore public and filtered, by construction.
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
  # One rule, and it is PERMANENT — not the scaffolding an earlier version of
  # this file called it.
  #
  # The original plan was: open 22 to the VPS for nixos-anywhere, then delete
  # the rule once the runner joined the tailnet and administration moved there.
  # The runner does not join the tailnet. modules/firewall.nix on the VPS
  # accepts `iifname tailscale0` with no source qualification, so a runner on
  # the tailnet reaches every port on that box — sshd on 2222, pgbouncer,
  # tempo's OTLP receiver, the mail ports — and the whole one-way design
  # evaporates. See the design doc's "Why the runner is not on the tailnet
  # either".
  #
  # So this is the admin path, for good:
  #
  #     ssh -J vps root@46.225.61.172
  #     nixos-anywhere --flake .#runner-hetzner \
  #       --ssh-option ProxyJump=vps root@46.225.61.172
  #
  # The public address, NOT the 10.0.1.3 an earlier revision named here — the
  # private NIC was removed in 5d0ae14, and the network itself is gone too, so
  # no address in that range exists on either host.
  #
  # It needs tcp/22 outbound on main-firewall, which tofu/modules/
  # hetzner-firewall grants to this /32 — AND a matching rule in the VPS's own
  # nftables output chain, which is policy-drop and did not have one. The cloud
  # rule alone is necessary and not sufficient.
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = ["167.233.24.58/32"]
    description = "Admin ssh, from the VPS only (ssh -J vps)"
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

  # NO TAILSCALE RULES. An earlier revision carried udp/443, udp/3478 and
  # udp/41641 so this box could join the tailnet once installed. It must not:
  # the VPS accepts `iifname tailscale0` unconditionally, so a tailnet runner
  # bypasses every one-way control this split exists to create. The absence is
  # the control — modules/runner/firewall.nix carries an assertion for the
  # host-side half.
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
  server_ids  = [for s in hcloud_server.runner : s.id]
}
