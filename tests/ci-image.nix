# ==============================================================================
# Can the nix-node job image actually run a JavaScript action?
# ==============================================================================
# modules/runner/ci-image.nix exists for exactly one reason: so that
# actions/checkout — and every other JavaScript action — has a `node` to be
# executed by inside the job container. That is a property of the built image,
# not of the Nix expression, and every way of checking it short of running the
# image is a proxy that can pass while the real thing is broken:
#
#   * the derivation builds       — says nothing about what is in the tarball
#   * nodejs is in the closure    — true even if it never lands on PATH
#   * `tar tzf` finds bin/node    — a layered image nests its layers, so this
#                                   greps the wrong tar and passes vacuously
#
# So this boots podman, loads the real image the runner would load, and runs
# things in it. The four assertions are the four things the runner needs and
# nothing else:
#
#   node    — the whole point; without it a `uses:` step dies at
#             `crun: executable file 'node' not found in $PATH` / exit 127
#   nix     — the image is useless to these workflows if `nix develop` is gone
#   git     — the hand-written fetch goes away, but checkout still needs git
#   sh      — the runner execs every `run:` block through a shell
#
# It also asserts the unit ORDERING, which is the failure that would otherwise
# only appear under load: a runner that starts before the load unit finishes
# advertises the nix-node label, can be handed a job immediately, and fails on
# a pull of a localhost/ reference no registry can serve.
#
# HAND-RUN, NOT IN CI, for the same reason tests/runner-firewall.nix is:
# `nix build .#checks.x86_64-linux.ci-image -L` needs /dev/kvm, and the CI box
# is a shared-vCPU Hetzner instance with no nested virtualisation. Booting a VM
# and loading a multi-hundred-megabyte image under TCG emulation is not a
# per-push cost. The structural half — that the label and the image reference
# cannot disagree — needs no test at all: modules/runner/identity.nix builds the
# label FROM config.runner.ciImageRef, so there is no second copy to drift.
{ nixpkgs, system }:

let
  pkgs = nixpkgs.legacyPackages.${system};
in
pkgs.testers.runNixOSTest {
  name = "ci-image";

  nodes.runner =
    { ... }:
    {
      imports = [
        ../modules/options.nix
        ../modules/runner/ci-image.nix
      ];

      virtualisation = {
        # podman only, not the whole runner module. Pulling in
        # modules/runner/default.nix would drag the daemon, its identity unit
        # and the metadata-service fetch that unit makes at boot into a VM that
        # has no Hetzner metadata service to answer it — the test would then be
        # measuring provisioning, not the image. ci-image.nix's load unit needs
        # podman and nothing else from that module.
        podman = {
          enable = true;

          # The collector this image has to survive. Enabled here with the same
          # flags the runner host uses, because the regression it caused —
          # `--all` deleting a cold image that nothing then reloads — is exactly
          # what the last block of the test script exercises.
          autoPrune = {
            enable = true;
            dates = "daily";
            flags = [ "--all" ];
          };
        };

        # The image is several hundred MB of nix and node closures and podman
        # unpacks it into the VM's own disk, which the harness sizes for a much
        # smaller machine by default.
        diskSize = 8192;
        memorySize = 3072;
      };

      # The load unit is ordered `before`/`requiredBy` forgejo-runner.service,
      # which does not exist here. A stub with the same name is what lets the
      # ordering edge be asserted rather than assumed — systemd silently ignores
      # a Before= naming a unit it has never heard of, so without this the test
      # would pass on a config whose ordering had been deleted.
      systemd.services.forgejo-runner = {
        description = "Stub standing in for the runner daemon";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };
    };

  testScript = ''
    runner.start()
    runner.wait_for_unit("forgejo-runner-ci-image.service")

    # Ordering, before anything else: if the runner can win the race the image
    # being correct does not help.
    runner.succeed(
        "systemctl show forgejo-runner.service -p After --value "
        "| grep -qw forgejo-runner-ci-image.service"
    )

    # The reference the label resolves to must be the tag podman now holds. Read
    # from the same option the label is built from, so this cannot be satisfied
    # by a tag that no workflow would ever ask for.
    ref = "${"localhost/forgejo-ci-nix-node:latest"}"
    runner.succeed(f"podman image exists {ref}")

    # The four things the runner needs, run in the image exactly as a job would
    # get it: no entrypoint override beyond the command, no PATH injected by the
    # test. `node --version` failing here IS the bug this image was built to fix.
    node_version = runner.succeed(f"podman run --rm {ref} node --version").strip()
    assert node_version.startswith("v22."), f"expected node 22, got {node_version!r}"

    runner.succeed(f"podman run --rm {ref} nix --version")
    runner.succeed(f"podman run --rm {ref} git --version")
    runner.succeed(f"podman run --rm {ref} sh -c 'echo shell-ok'")

    # nix must be able to READ its own database, not merely exist. Without
    # buildLayeredImageWithNixDb the store paths are present but unregistered,
    # and every `nix develop` rebuilds a closure that is already on the disk —
    # a silent, expensive regression that `nix --version` cannot see.
    registered = runner.succeed(
        f"podman run --rm {ref} nix-store -q --requisites ${pkgs.nodejs_22} | wc -l"
    ).strip()
    assert int(registered) > 1, (
        f"nix db does not know its own store paths (got {registered} requisites) — "
        "buildLayeredImageWithNixDb regressed to buildLayeredImage?"
    )

    # experimental-features baked into the image, so a workflow does not have to
    # set NIX_CONFIG to get a flake command to run.
    runner.succeed(f"podman run --rm {ref} nix flake --help >/dev/null")

    # ---------------------------------------------------------------- prune
    # The image has to survive its own garbage collector, and the first version
    # of this module did not. autoPrune runs `podman system prune -f --all`
    # daily; `--all` removes every image no container references, which between
    # jobs is this one. The load unit is a oneshot with RemainAfterExit, so once
    # it had succeeded at activation systemd never ran it again and nothing put
    # the image back until a reboot. Every job on the nix-node label then died
    # in about three seconds against a localhost/ reference no registry serves.
    #
    # Three steps, because each one can break independently.

    # 1. The image really is deletable — otherwise the rest proves nothing.
    runner.succeed(f"podman rmi -f {ref}")
    runner.fail(f"podman image exists {ref}")

    # 2. The loader can be made to run a SECOND time. `restart` and not `start`
    #    is the whole point: starting a RemainAfterExit oneshot systemd already
    #    considers active is a silent no-op, which is the trap being guarded.
    runner.succeed("systemctl restart forgejo-runner-ci-image.service")
    runner.succeed(f"podman image exists {ref}")

    # 3. The collector itself puts it back, via the ExecStartPost coupling.
    #    --no-block means the reload races the prune's own exit, so poll.
    runner.succeed("systemctl start podman-prune.service")
    runner.wait_until_succeeds(f"podman image exists {ref}", timeout=180)
  '';
}
