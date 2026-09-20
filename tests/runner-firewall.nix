# ==============================================================================
# Does the one-way rule actually hold?
# ==============================================================================
# The design doc's claim is that a compromised CI job cannot reach the VPS on
# anything but 443. That claim rests entirely on rule ORDER inside two nftables
# chains, which is invisible in review and silent when wrong — so it is tested
# rather than asserted.
#
# Two nodes. `vps` stands in for hu-tao and listens on 443 and 2222; `runner`
# gets the real modules/runner/firewall.nix with infra.publicIPv4 overridden to
# the vps node's test address. That override is why firewall.nix reads the
# option instead of inlining 167.233.24.58.
#
# THE FORWARD-CHAIN HALF IS THE POINT. Running podman inside a NixOS test would
# mean loading job images into a sandboxed VM, which is slow and tests podman
# rather than the ruleset. Instead the test builds a veth pair into a network
# namespace and NAMES THE HOST SIDE `podman9` — so it matches
# `iifname "podman*"`, the broad accept the VPS drop has to outrank. A packet
# from that namespace exercises exactly the path a job container's packet takes.
#
# Counters, not timeouts. A connection that hangs proves only that something
# dropped it; `nft list counter` proves WHICH rule did.
{ nixpkgs, system }:

let
  pkgs = nixpkgs.legacyPackages.${system};

  vpsAddr = "192.168.1.2";
in
pkgs.testers.runNixOSTest {
  name = "runner-firewall";

  nodes = {
    # Stands in for hu-tao. Two listeners: 443, which the runner must reach,
    # and 2222, which is the VPS's real sshd port and must be unreachable.
    vps =
      { pkgs, ... }:
      {
        networking.firewall.enable = false;
        systemd.services.listener-443 = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:443,fork,reuseaddr SYSTEM:'echo 443-ok'";
        };
        systemd.services.listener-2222 = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:2222,fork,reuseaddr SYSTEM:'echo 2222-ok'";
        };
      };

    # NOT the VPS, and that is its whole job. Without a third node the ingress
    # half could only show that ssh FROM the VPS is accepted, which was never
    # the half in doubt.
    #
    # NAMED `wan` DELIBERATELY. The harness assigns addresses in node-name
    # order, so anything sorting before `vps` would push it off 192.168.1.2 and
    # trip the guard in the test script. `wan` sorts after, and lands on .3 —
    # which is also the address the last subtest already used as a stand-in for
    # "somewhere that is not the VPS".
    wan =
      { pkgs, ... }:
      {
        networking.firewall.enable = false;
        environment.systemPackages = [ pkgs.netcat-openbsd ];
      };

    runner =
      { pkgs, ... }:
      {
        imports = [
          ../modules/options.nix
          ../modules/runner/firewall.nix
        ];

        # The override the whole test turns on: firewall.nix reads
        # config.infra.publicIPv4, so pointing it at the stand-in node exercises
        # the real rules against a real listener.
        infra.publicIPv4 = vpsAddr;

        # ip_forward comes from modules/runner/firewall.nix, which this node
        # imports — setting it here too is a duplicate definition.
        environment.systemPackages = [
          pkgs.iproute2
          pkgs.netcat-openbsd
          pkgs.nftables
        ];
      };
  };

  testScript = ''
    start_all()
    vps.wait_for_unit("listener-443.service")
    vps.wait_for_unit("listener-2222.service")
    wan.wait_for_unit("multi-user.target")
    runner.wait_for_unit("nftables.service")

    # Confirms the address the brief hardcodes is what the test harness
    # actually assigns, rather than assuming it — the harness orders nodes
    # alphabetically and starts at .1, so "vps" before "runner" gets .2, but
    # that ordering is a harness default, not a contract.
    actual_vps_addr = vps.succeed("ip -4 -o addr show dev eth1 | awk '{print $4}' | cut -d/ -f1").strip()
    assert actual_vps_addr == "${vpsAddr}", (
        "harness assigned vps the address '" + actual_vps_addr + "', not '${vpsAddr}' — "
        "update vpsAddr in tests/runner-firewall.nix"
    )

    actual_wan_addr = wan.succeed("ip -4 -o addr show dev eth1 | awk '{print $4}' | cut -d/ -f1").strip()
    assert actual_wan_addr != "${vpsAddr}", (
        "harness gave wan the VPS's address '" + actual_wan_addr + "' — "
        "the 'nothing else may ssh in' subtest would be testing nothing"
    )

    def counter(name):
        out = runner.succeed(f"nft list counter inet nixos-fw {name}")
        # `counter vps_blocked_fwd { packets 3 bytes 180 }`
        return int(out.split("packets")[1].split()[0])

    # ── input chain: who may ssh in ───────────────────────────────────────
    # THE COUNTERS ARE THE ASSERTION, not nc's exit status. This runner node
    # imports only options.nix and firewall.nix, so no sshd is listening and a
    # permitted connection is refused exactly like a filtered one is — the exit
    # status cannot tell the two apart, and that is the whole question here.
    runner_addr = runner.succeed(
        "ip -4 -o addr show dev eth1 | awk '{print $4}' | cut -d/ -f1"
    ).strip()

    with subtest("the VPS may ssh in"):
        before = counter("ssh_from_vps")
        vps.execute(f"timeout 5 nc -z {runner_addr} 22")
        assert counter("ssh_from_vps") > before, \
            "ssh from the VPS did not match the allow rule — the runner is now unreachable"

    with subtest("nothing else may ssh in"):
        before_allowed = counter("ssh_from_vps")
        before_blocked = counter("ssh_blocked")
        wan.execute(f"timeout 5 nc -z {runner_addr} 22")
        assert counter("ssh_blocked") > before_blocked, \
            "ssh from a non-VPS host did not hit the drop — the host rule is not narrowing"
        assert counter("ssh_from_vps") == before_allowed, \
            "ssh from a non-VPS host matched the VPS allow rule — check the ip saddr match"

    # ── output chain: the host's own traffic ──────────────────────────────
    with subtest("the host reaches the VPS on 443"):
        before = counter("vps_allowed_out")
        runner.succeed("timeout 5 nc -z ${vpsAddr} 443")
        assert counter("vps_allowed_out") > before, "443 was not matched by the allow rule"

    with subtest("the host cannot reach the VPS on 2222"):
        before = counter("vps_blocked_out")
        runner.fail("timeout 5 nc -z ${vpsAddr} 2222")
        assert counter("vps_blocked_out") > before, "2222 was not matched by the VPS drop"

    # ── forward chain: what a job container's packet actually does ────────
    # podman9, not veth0: the name is what makes this traverse the same
    # `iifname "podman*"` accept a real per-job bridge does, which is the rule
    # the VPS drop has to outrank.
    with subtest("a job container cannot reach the VPS on 2222"):
        runner.succeed("ip netns add job")
        runner.succeed("ip link add podman9 type veth peer name eth0 netns job")
        runner.succeed("ip addr add 10.88.9.1/24 dev podman9")
        runner.succeed("ip link set podman9 up")
        runner.succeed("ip -n job addr add 10.88.9.2/24 dev eth0")
        runner.succeed("ip -n job link set eth0 up")
        runner.succeed("ip -n job route add default via 10.88.9.1")

        before = counter("vps_blocked_fwd")
        runner.fail("timeout 5 ip netns exec job nc -z ${vpsAddr} 2222")
        assert counter("vps_blocked_fwd") > before, \
            "a container's packet to the VPS on 2222 did not hit the forward drop — " \
            "check that the VPS rules sit ABOVE `iifname \"podman*\" accept`"

    with subtest("a job container is permitted to reach the VPS on 443"):
        before = counter("vps_allowed_fwd")
        # The SYN is accepted by the forward chain; whether the handshake
        # completes depends on a return route the test does not build, so the
        # assertion is on the counter and not on nc's exit status.
        runner.execute("timeout 5 ip netns exec job nc -z ${vpsAddr} 443")
        assert counter("vps_allowed_fwd") > before, "443 from a container was not matched by the allow rule"

    with subtest("the VPS drop did not swallow ordinary container egress"):
        before = counter("vps_blocked_fwd")
        runner.execute("timeout 5 ip netns exec job nc -z 192.168.1.3 80")
        assert counter("vps_blocked_fwd") == before, \
            "traffic to a non-VPS address hit the VPS drop"
  '';
}
