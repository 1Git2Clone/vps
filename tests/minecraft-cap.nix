# ==============================================================================
# Minecraft — the running-worlds cap and minecraft-scaler, end to end
# ==============================================================================
# Imports the real modules/containers/minecraft-cap.nix against three stand-in
# worlds (sleep, not docker: what is under test is systemd's view of the units,
# not the containers). The mc network's two addresses are put on a dummy link,
# so the scaler binds and filters exactly as it does on the box.
#
# Hand-run, like runner-firewall: it needs /dev/kvm.
#   nix build .#checks.x86_64-linux.minecraft-cap -L
{ nixpkgs, system }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  worlds = [
    "w1"
    "w2"
    "w3"
  ];
in
pkgs.testers.runNixOSTest {
  name = "minecraft-cap";

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [
        ../modules/options.nix
        ../modules/containers/minecraft-cap.nix
      ];

      minecraftCap.worlds = worlds;
      minecraftCap.alwaysOnWorlds = [ "horizon" ];

      environment.systemPackages = [ pkgs.curl ];

      systemd.services =
        lib.genAttrs (map (w: "docker-${w}") worlds) (_: {
          serviceConfig = {
            ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
            # As on the box (modules/containers/default.nix): a refused start
            # must not turn into a retry loop.
            Restart = "always";
            RestartSec = 1;
          };
        })
        // {
          docker-horizon = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
          };
          # Stands in for docker creating the bridge: the gateway the scaler
          # binds, mc-router's address, and one more on the same subnet.
          "docker-network-${config.infra.mcNetwork}" = {
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            path = [ pkgs.iproute2 ];
            script = ''
              ip link add mc0 type dummy
              ip addr add ${config.infra.mcGateway}/24 dev mc0
              ip addr add ${config.infra.mcRouterAddress}/32 dev mc0
              ip addr add 172.31.0.3/32 dev mc0
              ip link set mc0 up
            '';
          };
        };
    };

  testScript = ''
    import json

    url = "http://172.31.0.1:25580/scale"


    def scale(action, world, source="172.31.0.2"):
        body = json.dumps({"action": action, "serverAddress": "", "backend": f"{world}:25565"})
        return machine.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' --interface {source} -m 10 "
            f"-H 'Content-Type: application/json' -d '{body}' {url}"
        ).strip()


    def state(world):
        return machine.succeed(f"systemctl show -P ActiveState docker-{world}.service").strip()


    def up_count():
        return sum(state(w) not in ("inactive", "failed") for w in ["w1", "w2", "w3"])


    machine.wait_for_unit("minecraft-scaler.service")
    machine.wait_for_unit("docker-horizon.service")
    # Not wait_for_open_port: that probes from an address IPAddressDeny drops.
    machine.wait_until_succeeds(f"curl -s --interface 172.31.0.2 -m 2 -o /dev/null {url}")

    with subtest("always-on routes accept callbacks and never stop on idle"):
        assert scale("up", "horizon") == "200"
        assert scale("down", "horizon") == "200"
        assert state("horizon") == "active"
        machine.succeed("systemctl stop docker-horizon.service")
        assert scale("up", "horizon") == "200"
        assert state("horizon") == "inactive"
        assert scale("up", "unknown-world") == "400"

    with subtest("the cap refuses a third world, and answers 409"):
        assert scale("up", "w1") == "200"
        assert scale("up", "w2") == "200"
        assert scale("up", "w3") == "409"
        assert state("w3") == "inactive", state("w3")

    with subtest("a refused start is skipped, not failed, so Restart= never loops"):
        machine.succeed("systemctl start docker-w3.service")
        machine.sleep(3)
        assert state("w3") == "inactive", state("w3")
        assert machine.succeed("systemctl show -P NRestarts docker-w3.service").strip() == "0"

    with subtest("down frees a slot"):
        assert scale("down", "w1") == "202"
        machine.wait_until_succeeds("systemctl show -P ActiveState docker-w1.service | grep -qx inactive")
        assert scale("up", "w3") == "200"

    with subtest("the hold file refuses every start"):
        machine.succeed("systemctl stop docker-w2.service docker-w3.service")
        machine.succeed("touch /run/minecraft-hold")
        assert scale("up", "w1") == "409"
        machine.succeed("rm /run/minecraft-hold")
        assert scale("up", "w1") == "200"

    with subtest("starting all three at once still lands on two"):
        machine.succeed("systemctl stop docker-w1.service")
        machine.succeed("systemctl start --no-block docker-w1.service docker-w2.service docker-w3.service")
        machine.sleep(3)
        assert up_count() == 2, up_count()

    with subtest("anything but a known world's up/down is a 400"):
        assert scale("up", "minecraft-evil") == "400"
        assert scale("restart", "w1") == "400"
        assert machine.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' --interface 172.31.0.2 -m 10 -d 'not json' {url}"
        ).strip() == "400"

    with subtest("only mc-router's address reaches the scaler"):
        machine.fail(f"curl -s --interface 172.31.0.3 -m 5 -d '{{}}' {url}")
  '';
}
