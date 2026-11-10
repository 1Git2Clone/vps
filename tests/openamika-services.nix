# Real Docker startup under a non-root uid and the production read-only mounts.
# A VM preserves root ownership of store paths. Unprivileged bwrap maps root to
# nobody, which NLTK correctly refuses as an untrusted owner of corpus files.
{
  pkgs,
  openamika,
  container,
}:
let
  environment = pkgs.writeText "openamika-test-environment.json" (
    builtins.toJSON openamika.runtimeEnvironment
  );
in
pkgs.testers.runNixOSTest {
  name = "openamika-services";
  nodes.machine = { config, lib, ... }: {
    networking.useDHCP = false;
    virtualisation = {
      # Leave guest-kernel/Docker headroom outside the unchanged 8 GiB container cap.
      memorySize = 10240;
      cores = 4;
      diskSize = 2048;
      docker.enable = true;
      oci-containers.backend = "docker";
      oci-containers.containers.openamika = container // {
        # Run the health harness instead of main(), but use main's own Service
        # definitions and the real runtime's mutable-default initialization.
        entrypoint = "${openamika.envs.brain}/bin/python";
        cmd = [
          "/smoke.py"
          "${openamika.runtime}/bin/openamika-runtime"
        ];
        environmentFiles = [ ];
        volumes = container.volumes ++ [
          "${../pkgs/openamika/check-services.py}:/smoke.py:ro"
          "${environment}:/runtime-env.json:ro"
        ];
      };
    };
    systemd.services.docker-openamika = {
      path = lib.mkBefore [
        (import ../pkgs/openamika/docker-wrapper.nix {
          inherit pkgs;
          docker = "${config.virtualisation.docker.package}/bin/docker";
          closure = openamika.runtimeClosure;
        })
      ];
      preStart = ''
        docker network inspect openamika >/dev/null 2>&1 || \
          docker network create --internal --subnet=172.29.0.0/24 openamika
        docker volume create openamika_data >/dev/null
        install -d -m0700 -o 1000004 -g 1000004 /var/lib/docker/volumes/openamika_data/_data
      '';
      serviceConfig.Restart = lib.mkForce "no";
    };
  };
  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("docker.service")
    # Store ownership is part of the real conditions (in particular NLTK).
    machine.succeed("test $(stat -c %u ${openamika.assets.nltk}) = 0")
    machine.succeed("systemctl start docker-openamika.service")
    try:
        machine.wait_until_succeeds("test $(docker container inspect --format '{{.State.Running}}' openamika) = true", timeout=60)
        mounts = json.loads(machine.succeed("docker container inspect --format '{{json .Mounts}}' openamika"))
        with open("${openamika.runtimeClosure}/store-paths") as file:
            expected = set(file.read().splitlines())
        store_mounts = [mount for mount in mounts if mount["Destination"].startswith("/nix/store/")]
        assert {mount["Destination"] for mount in store_mounts} == expected
        assert all(mount["Source"] == mount["Destination"] and not mount["RW"] for mount in store_mounts)
        assert not any(mount["Destination"] == "/nix/store" for mount in mounts)
        machine.wait_until_succeeds(
            "journalctl -u docker-openamika --no-pager | grep 'All services healthy with read-only runtime closure' || systemctl is-failed --quiet docker-openamika",
            timeout=1200,
        )
        for name in ["tts", "embedder", "brain", "speech", "messengers"]:
            machine.succeed(f"journalctl -u docker-openamika --no-pager | grep 'HEALTHY {name}:'")
        machine.wait_until_succeeds("test $(systemctl show -p ActiveState --value docker-openamika) = inactive", timeout=120)
        machine.succeed("test $(systemctl show -p Result --value docker-openamika) = success")
    finally:
        print(machine.succeed("journalctl -u docker-openamika --no-pager"))
  '';
}
