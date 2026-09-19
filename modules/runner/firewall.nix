# ==============================================================================
# The runner's firewall — the one-way rule, enforced
# ==============================================================================
# THE REQUIREMENT: the runner may not initiate anything toward the VPS except
# HTTPS to Forgejo. Everything below exists to make that true rather than
# asserted.
#
# What the cloud level does, and what it cannot. hcloud firewalls filter the
# PUBLIC interface only and have no deny rules — an empty rule set in a
# direction means allow-everything, not deny. So the cloud level does the
# structural half and nothing finer:
#
#   * no private NIC (removed in 5d0ae14), so there is no unfiltered path;
#   * one ingress rule, tcp/22 from 167.233.24.58/32, so only the VPS knocks;
#   * a named egress allow-list, because a runner with no egress cannot pull a
#     job image or resolve crates.io.
#
# It cannot express "443 to that host, nothing else to that host". That is this
# file.
#
# THREE THINGS THAT ARE EASY TO GET WRONG AND SILENT WHEN WRONG.
#
# 1. RULE ORDER. nftables is first-match-wins within a chain. The VPS drop must
#    sit ABOVE the broad accepts — `iifname "podman*" accept` in forward, and
#    the port allow-lists in output — or a job container reaches the VPS on
#    every port and the ruleset looks correct while enforcing nothing. This is
#    the single most important property in the file and Task 5's VM test exists
#    for it specifically.
#
# 2. THE FORWARD CHAIN, NOT ONLY OUTPUT. Job containers have their own network
#    namespace, so their packets are FORWARDED by this host and never emitted
#    by it. An output-only rule is bypassed by every container on the box —
#    which is the exact shape of the forward-chain problem this infrastructure
#    has already been bitten by twice (see modules/firewall.nix, and the
#    fail2ban chain_hook comment in modules/services.nix).
#
# 3. IPv6. `ip daddr` matches IPv4 ONLY. The VPS holds primary IPv6
#    2a01:4f8:c015:b138::/64, so a v4-only rule leaves the whole /64 open. DNS
#    publishes no AAAA for anything on the VPS (tofu/server.tf), so nothing
#    legitimate goes there over v6 and the /64 is dropped outright with no
#    443 exception.
#
# AND THE ONE THAT IS NOT A RULE: there is no tailscale on this host. The VPS's
# input chain accepts `iifname tailscale0` unconditionally, so a runner on the
# tailnet would reach every port on it and none of this file would ever see the
# traffic. See runner/configuration.nix.
#
# WHAT THIS FILE IS NOT: a boundary against a HOSTILE job. container.docker_host
# in modules/runner/default.nix hands every job container podman's own socket,
# not a restricted one, and a job that gets root on this box through it can run
# `nft flush ruleset` or replace this table outright — the daemon runs on the
# same kernel this ruleset filters, with the same root. A passing VM test in
# Task 5 proves the rules are correctly ordered against an ACCIDENTAL or
# UNPRIVILEGED packet; it says nothing about a workflow that has already
# escaped to root, and must never be read as though it does.
#
# What still holds when this table is gone, because neither lives in this VM:
#
#   * the Hetzner cloud firewall's egress allow-list — tcp/53, udp/53, tcp/443,
#     tcp/80, udp/123, and NOTHING else: no 22, 25, 465, 587, 993 or 2222, so
#     the VPS's ssh and mail ports stay unreachable from this box at the cloud
#     edge no matter what a rooted job does to the host ruleset. There is also
#     no private NIC, so there is no second path around it.
#   * caddy's path allowlist on the VPS — PLANNED, NOT YET IN PLACE. It will
#     live in modules/containers/caddy.nix, which today proxies git.<domain>
#     wholesale with no path matcher and no git-receive-pack denial. Until
#     that lands, a job that gets root on this box can reach the VPS on 443
#     and gets FORGEJO'S ENTIRE http surface there — the web UI, /api/v1/*,
#     every repo over git-http including git-receive-pack — because the cloud
#     firewall has to allow 443 outbound for CI to work at all, and an hcloud
#     allow-list cannot express "all of 443 except this one host". Correct
#     this comment when that module gets the matcher.
#
# So: this file is DEFENCE IN DEPTH, not the boundary. It stops accidental and
# unprivileged reach — the ordinary case, and the case the header above is
# entirely about — and it is the layer a non-root process on this box actually
# hits. The layer that holds against a rooted job is off this VM entirely, in
# tofu today, and in caddy's config on the VPS once it gets the matcher named
# above.
{ config, lib, ... }:

let
  vps4 = config.infra.publicIPv4;

  # The /64, not the single address. Hetzner routes the whole prefix to the
  # server and anything in it is the VPS.
  #
  # NOT read from infra.* because no option holds it — it is
  # hcloud_primary_ip.main_v6 in tofu and nothing in NixOS needed it until now.
  # If the VPS is ever rebuilt with a new prefix, this is the line to change,
  # and Task 5's VM test will not catch it because the test is v4-only.
  vps6 = "2a01:4f8:c015:b138::/64";

  # infra.cacheProxyPort (modules/options.nix), shared with
  # modules/runner/default.nix so the two cannot drift apart. Job containers
  # reach the Actions cache proxy at the host's own address, which makes it
  # input rather than forward.
  cacheProxyPort = config.infra.cacheProxyPort;
in
{
  networking.nftables = {
    enable = true;

    # Same reason as the VPS's, one engine down: podman/netavark builds its own
    # tables when a network is created, and a flush wipes them. Unlike docker,
    # netavark rebuilds them per network rather than at daemon start, so the
    # blast radius is smaller — but "smaller" is not a reason to flush.
    flushRuleset = false;

    ruleset = ''
      table inet nixos-fw { }
      delete table inet nixos-fw

      table inet nixos-fw {
        # Named counters, so the VM test in tests/runner-firewall.nix can prove
        # which rule a packet hit rather than inferring it from a timeout. A
        # timeout is consistent with "dropped by the right rule" and with
        # "dropped by the default policy for an unrelated reason"; a counter is
        # not.
        counter vps_blocked_out { }
        counter vps_blocked_out6 { }
        counter vps_blocked_fwd { }
        counter vps_blocked_fwd6 { }
        counter vps_allowed_out { }
        counter vps_allowed_fwd { }

        chain input {
          type filter hook input priority filter; policy drop;

          iifname lo accept
          ct state { established, related } accept

          # Administration, permanently. The cloud firewall is what narrows the
          # source to 167.233.24.58/32 — this rule cannot, because a host rule
          # keyed on the VPS's address would also have to survive the VPS's
          # address changing, and the cloud rule is the one tofu owns.
          tcp dport 22 ct state new accept

          # The Actions cache proxy, reached by job containers at this host's
          # own address. `cache.host` is unset in modules/runner/default.nix, so
          # the runner advertises the outbound address it detects — the public
          # IPv4 — and a container's packet to it is routed through the
          # container's gateway (this host) and delivered locally, arriving here
          # with the per-job bridge as iifname.
          #
          # netavark names those bridges podman0, podman1, … so the wildcard
          # covers the default network and every per-job one. Narrow to the
          # port rather than accepting the bridges wholesale: there is no reason
          # a job container should reach this host's sshd.
          iifname "podman*" tcp dport ${toString cacheProxyPort} ct state new accept

          # IPv6's link layer, not a courtesy — path MTU discovery and neighbour
          # discovery break without it, and the failures are slow rather than
          # loud.
          icmpv6 type {
            destination-unreachable,
            packet-too-big,
            time-exceeded,
            parameter-problem,
            nd-router-solicit,
            nd-neighbor-solicit,
            nd-neighbor-advert,
            echo-request
          } accept
          icmp type echo-request accept

          log prefix "DROP_in: " counter drop
        }

        chain output {
          type filter hook output priority filter; policy drop;

          oifname lo accept
          ct state { established, related } accept

          # ── THE ONE-WAY RULE, and it is FIRST on purpose ──────────────────
          # Above every broad accept below. Reordering these three lines below
          # the port allow-list silently unenforces the whole design, because
          # `tcp dport 443` would match before the drop ever ran and so would
          # anything else on the list.
          ip daddr ${vps4} tcp dport 443 ct state new counter name vps_allowed_out accept
          ip daddr ${vps4} counter name vps_blocked_out log prefix "DROP_vps_out: " drop
          ip6 daddr ${vps6} counter name vps_blocked_out6 log prefix "DROP_vps_out6: " drop

          # The host's own traffic to its containers, across the podman
          # bridges. This is the second half of the bug documented in
          # modules/firewall.nix's output chain: a host-originated connection to
          # a container leaves through here, not forward.
          oifname "podman*" accept

          # 80 is two things: the metadata service on 169.254.169.254 that
          # modules/runner/identity.nix reads, and substituters that have not
          # moved to https.
          tcp dport { 53, 80, 443 } ct state new accept
          # 67 is the DHCP client renewing its lease. No 41641/3478 — there is
          # no tailscale on this host.
          udp dport { 53, 67, 123, 443 } ct state new accept

          icmpv6 type {
            destination-unreachable,
            packet-too-big,
            time-exceeded,
            parameter-problem,
            nd-router-solicit,
            nd-neighbor-solicit,
            nd-neighbor-advert,
            echo-request
          } accept
          icmp type echo-request accept

          log prefix "DROP_out: " counter drop
        }

        chain forward {
          type filter hook forward priority filter; policy drop;

          ct state { established, related } accept

          # ── THE ONE-WAY RULE AGAIN, and this is the copy that matters ─────
          # Job containers are in their own netns, so every packet a WORKFLOW
          # sends is forwarded and never touches the output chain above. Above
          # `iifname "podman*" accept` for the same first-match reason.
          #
          # Note the established/related accept above it does not open a hole:
          # established only ever matches after a NEW packet was accepted, and a
          # NEW packet to the VPS on anything but 443 never is.
          ip daddr ${vps4} tcp dport 443 ct state new counter name vps_allowed_fwd accept
          ip daddr ${vps4} counter name vps_blocked_fwd log prefix "DROP_vps_fwd: " drop
          ip6 daddr ${vps6} counter name vps_blocked_fwd6 log prefix "DROP_vps_fwd6: " drop

          # Container egress to the internet, and container-to-container on a
          # per-job network. Everything a job legitimately does goes through
          # here, which is why the two rules above have to come first.
          iifname "podman*" accept

          log prefix "DROP_fwd: " counter drop
        }
      }
    '';
  };

  # Packet forwarding, which podman would enable at runtime anyway. Declared so
  # that the forward chain above is not filtering a path the kernel happens to
  # have open for reasons outside this repo.
  #
  # v4 only — there is no net.ipv6.conf.all.forwarding here, which makes the
  # forward chain's ip6 drop unreachable today. Left in anyway, deliberately:
  # belt-and-braces for the day v6 forwarding gets turned on, so it is not
  # rediscovered as a hole the hard way. Do not delete it as dead code.
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  assertions = [
    {
      assertion = !config.networking.nftables.flushRuleset;
      message = ''
        networking.nftables.flushRuleset must stay false on the runner. The
        flush wipes the tables netavark owns, and a container network whose
        rules have been wiped loses connectivity without the container dying.
      '';
    }
    {
      # The whole design keyed on infra.publicIPv4 is worthless if it is empty.
      assertion = config.infra.publicIPv4 != "";
      message = "infra.publicIPv4 is empty; the runner's one-way rules would match nothing.";
    }
    {
      assertion = !config.services.tailscale.enable;
      message = ''
        tailscale must stay disabled on the runner. The VPS's input chain
        accepts `iifname tailscale0` unconditionally, so a runner on the tailnet
        reaches every port on it — sshd on 2222, pgbouncer, tempo, the mail
        ports — and none of the one-way rules in this file would ever see that
        traffic.
      '';
    }
  ];
}
