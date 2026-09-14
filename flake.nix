{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The circuit breaker. See the `deploy` output below.
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      sops-nix,
      deploy-rs,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Which systems get a dev shell. `system` above is the DEPLOY TARGET; the
      # shell is entered on a workstation, which is routinely a Mac. Every tool
      # in the shell below is available on all four — including nixos-anywhere,
      # nixos-rebuild and deploy-rs — so one list serves them all. Everything
      # that describes the box itself (nixosConfigurations, packages, apps)
      # stays pinned to `system`.
      #
      # These are nixpkgs' four mainstream systems. Listing one costs nothing
      # until someone actually enters that shell — the attribute is lazy and
      # nothing is fetched or built for a system nobody uses — so the list is
      # the full set rather than only the ones known to be in use today.
      devSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      mkVps =
        extraModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./configuration.nix
            ./disk-config.nix
            disko.nixosModules.disko
            sops-nix.nixosModules.sops
          ]
          ++ extraModules;
        };

      # The local QEMU VM. disk-config.nix targets /dev/vda, which is what
      # virtio gives it.
      vps = mkVps [ ];

      # What tofu installs. Hetzner Cloud presents the root disk as /dev/sda, so
      # the two configurations differ in exactly one line — everything else,
      # including every container, is shared.
      vps-hetzner = mkVps [
        { disko.devices.disk.main.device = "/dev/sda"; }
      ];
    in
    {
      nixosConfigurations = {
        inherit vps vps-hetzner;
      };

      # ── Circuit breaker ────────────────────────────────────────────────────
      # `deploy .#vps` activates the new closure, then waits for confirmation
      # over a FRESH connection. If that connection cannot be made — the case
      # where a bad firewall or sshd change has locked you out, which is the
      # failure you genuinely cannot recover from without the Hetzner console —
      # the box rolls itself back to the previous generation unattended.
      #
      # What this does and does not cover, stated plainly so nobody is surprised
      # mid-incident:
      #
      #   lockout (firewall / sshd / networking)  → auto-rollback, this
      #   unbootable kernel or initrd             → GRUB generation menu, 5s timeout
      #   a container fails to start              → NOT auto-rolled back; you
      #                                             still have ssh, so
      #                                             `nixos-rebuild --rollback`
      #
      # The last one is deliberate. deploy-rs confirms reachability, not service
      # health, and a container crashlooping is both visible and recoverable —
      # rolling the whole system back for it would be the wrong reflex.
      deploy.nodes.vps = {
        # The MagicDNS name, not an IP: it survived the primary-IP swap during
        # the migration, so the same command works before and after a cutover.
        #
        # This is the tailnet node name, which is NOT the same thing as
        # networking.hostName — renaming the machine in the tailscale admin
        # console changes it and silently breaks deploys with
        # "Host key verification failed" or a DNS failure. Check with
        # `tailscale status` if a deploy suddenly cannot reach the box.
        hostname = "vps";

        profiles.system = {
          sshUser = "hutao";
          user = "root";
          path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.vps-hetzner;

          # Port 2222 reaches the host's own sshd. Going through the default
          # port would hit forgejo, and going through Tailscale SSH would hit
          # its interactive re-auth check — neither of which can be scripted.
          sshOpts = [
            "-p"
            "2222"
          ];

          magicRollback = true;
          autoRollback = true;

          # Long enough for every container to be recreated on a config change,
          # short enough that a hung activation is not an outage.
          confirmTimeout = 120;

          # 15 minutes, raised from 300s for the serenity-bot image build.
          #
          # That build runs INSIDE activation: serenity-bot-image.service is a
          # Type=oneshot wanted by multi-user.target, so switch-to-configuration
          # starts it and blocks on a Rust release build. Upstream's Dockerfile
          # has no cargo-chef layer — `COPY . .` then `cargo build` — so EVERY
          # rev bump invalidates the whole build, not just the first one.
          #
          # MEASURED on this host, 2026-09-04, cold cache including the
          # rust:1.94-bullseye and debian:bullseye-slim pulls: 3m28s
          # (cargo itself 3m03s). 900s is ~4x that.
          #
          # An earlier version of this comment guessed "tens of minutes" and set
          # 2100s. That was wrong by an order of magnitude, and the guess is why
          # the number is now written down with a date next to it: 300s would
          # have very nearly worked, at about 17% headroom, which is too thin
          # for a slower network or a loaded box but nowhere near needing 35
          # minutes. Re-measure rather than re-guess if the build grows.
          #
          # Deliberately LONGER than the build unit's own TimeoutStartSec
          # (10min, in modules/containers/serenity-bot.nix). The unit therefore
          # gives up first, and an overrun reads as
          # "serenity-bot-image.service: Start operation timed out" instead of
          # an unexplained rollback. Keep that ordering if either number moves.
          #
          # The cost is still borne by every deploy, so the durable fix stands:
          # build the image off-box — same architecture, so a native build here
          # and a pushed closure there, not a cross-compile — and ship it as an
          # imageFile so activation only does `docker load`.
          activationTimeout = 900;
        };
      };

      # deployChecks gives two checks, and only one of them was ever meant to be
      # built here. `deploy-activate` references the whole system closure by
      # design, so it is evaluated and never built — that is what the
      # `--no-build` on CI's `nix flake check` is for.
      #
      # `deploy-schema` LOOKS like the cheap one and is not. The check itself is
      # a single command:
      #
      #   check-jsonschema --schemafile interface.json deploy.json
      #
      # but deploy.json carries the activation path as a CONTEXT-BEARING string
      # — `"path": "/nix/store/...-activatable-nixos-system-hu-tao-..."` — and a
      # string with context is a build input. So realising that 200-byte JSON
      # realises the system closure, and deploy-rs with it FROM SOURCE: it
      # `follows` our nixpkgs, so its binary is a cache miss and CI compiles
      # ~200 Rust crates to validate a document it already has.
      #
      # MEASURED on the Forgejo runner, 2026-09-12: 4m43s and still compiling,
      # in a step whose comment claimed "no Rust toolchain and no system
      # closure". The derivation graph is 5367 paths; the same JSON comes out of
      # `nix eval --json .#deploy` in 5.9s.
      #
      # unsafeDiscardStringContext is what cuts the link. The bytes do not
      # change — the path is still spelled out in full and still validated
      # against the schema — but Nix stops treating it as something to build.
      # `unsafe` means one specific thing: the store path in the output is no
      # longer guaranteed to exist. That is correct for a file handed to a
      # schema validator, which reads it as a string. It would NOT be correct
      # for anything that dereferences the path, so do not copy this idiom into
      # a check that actually deploys.
      checks =
        let
          deployJson = pkgs.writeText "deploy.json" (
            builtins.unsafeDiscardStringContext (builtins.toJSON self.deploy)
          );
        in
        nixpkgs.lib.recursiveUpdate
          (builtins.mapAttrs (_system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib)
          {
            ${system} = {
              # Same attribute name deployChecks used, so CI's
              # `nix build .#checks.x86_64-linux.deploy-schema` is unchanged.
              deploy-schema = pkgs.runCommand "deploy-schema" { } ''
                ${pkgs.check-jsonschema}/bin/check-jsonschema \
                  --schemafile ${deploy-rs}/interface.json ${deployJson}
                touch $out
              '';

              # The guard on the check above, and the reason it is not redundant:
              # a validator that silently does nothing passes forever. If the
              # schemafile path ever goes stale, or check-jsonschema changes how
              # it takes arguments, `deploy-schema` keeps exiting 0 over a
              # document it never read — and we would not find out until a broken
              # deploy.json reached a real deploy.
              #
              # So: feed the SAME invocation a node with no `hostname`, which
              # interface.json marks required, and fail if it is accepted.
              deploy-schema-rejects-bad-input = pkgs.runCommand "deploy-schema-rejects-bad-input" { } ''
                if ${pkgs.check-jsonschema}/bin/check-jsonschema \
                     --schemafile ${deploy-rs}/interface.json \
                     ${
                       pkgs.writeText "bad-deploy.json" (builtins.toJSON { nodes.vps.profiles.system.path = "/dev/null"; })
                     } >/dev/null 2>&1
                then
                  echo "schema validation accepted a node with no hostname" >&2
                  exit 1
                fi
                touch $out
              '';
            };
          };

      devShells = nixpkgs.lib.genAttrs devSystems (
        devSystem:
        let
          pkgs = nixpkgs.legacyPackages.${devSystem};
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              nixd
              # nixfmt, not nixpkgs-fmt: every .nix file in this repo is formatted
              # with it and the two disagree on multi-argument lambdas, so the wrong
              # one here reformats the whole tree on first use.
              nixfmt-rfc-style
              statix
              sops
              age
              ssh-to-age
              nixos-anywhere
              # The deploy fallback. nixos-rebuild ships with NixOS, so it is NOT on
              # a non-NixOS workstation unless it is here — and the fallback is
              # worthless if it cannot be run on the machine you deploy from.
              nixos-rebuild
              opentofu
              deploy-rs.packages.${devSystem}.default
              # The hook runner. `pre-commit install` once per clone, after which
              # .pre-commit-config.yaml is enforced on every commit; the same file
              # is what CI runs, so the two cannot drift.
              pre-commit
              gitleaks
            ];
          };

          # What CI enters. Deliberately NOT the full dev shell: that one pulls
          # nixos-anywhere, nixos-rebuild, opentofu and deploy-rs, none of which a
          # formatting check needs, and all of which CI would download every run.
          ci = pkgs.mkShell {
            buildInputs = with pkgs; [
              pre-commit
              nixfmt-rfc-style
              statix
              opentofu # tofu fmt
              git
              gitleaks
            ];
          };

          # What .forgejo/workflows/renovate.yml enters, and separate from `ci`
          # for the same reason `ci` is separate from `default`: Renovate is a
          # node runtime and a large closure, and ci runs on every push and
          # every pull request. An entry in `ci` would make all of them download
          # it for a job that never calls it.
          #
          # Pinned through this flake rather than run from the registry, so the
          # thing that proposes updates is itself a line in flake.lock —
          # lockFileMaintenance bumps Renovate exactly like everything else.
          renovate = pkgs.mkShell {
            buildInputs = with pkgs; [
              renovate
              # Renovate shells out for lock maintenance rather than editing
              # flake.lock itself, and its git work happens through the git on
              # PATH. Both are in the job's image already; naming them here is
              # what makes `nix develop .#renovate` work off a workstation too.
              nix
              git
              # Same reason as `nix`, for a different manager. RENOVATE_BINARY_SOURCE
              # is `global`, so Renovate never installs a toolchain of its own — it
              # spawns whatever is on PATH. With no pnpm there, every npm-manager
              # repo the bot discovers dies on
              #
              #   spawn pnpm ENOENT  (unhandledRejection, exit 1)
              #
              # and — because the crash happens in the lockfile step, after the
              # branch is pushed — it opens the pull request anyway, with the
              # lockfile untouched and an `artifactErrors` comment on it. hutao/vps
              # has no package.json and was never affected; skavex/skavex is.
              #
              # pnpm_10 and not pnpm: skavex's pnpm-lock.yaml is lockfileVersion
              # '9.0' and it declares no `packageManager` field, so nothing tells
              # Renovate which major to use. nixpkgs' unversioned `pnpm` is 11, and
              # a major that rewrites the lockfile format would turn every update
              # into a whole-file diff. Pin it to the major that wrote the lock.
              pnpm_10
            ];
          };
        }
      );

      packages.${system}.default = vps.config.system.build.toplevel;

      apps.${system} = {
        # ── Initial install, in one command ────────────────────────────────────
        #   nix run .#install -- root@<ip>
        #
        # This exists because the one genuinely manual step in a NixOS install is
        # unavoidable and easy to forget: the target must hold a decryption key
        # BEFORE its first activation, or sops-install-secrets fails and the
        # machine boots with no credentials — including its own root and user
        # passwords. You cannot bootstrap a secret from nothing.
        #
        # What it does that a bare nixos-anywhere invocation does not:
        #   * checks the age key actually decrypts secrets.yaml first, so the
        #     failure happens here rather than three minutes into an install
        #   * stages it into an extra-files tree at 0600, in a temp dir that is
        #     cleaned up, instead of a hand-made directory that lingers
        #   * selects vps-hetzner, not vps — the wrong one targets /dev/vda and
        #     fails at disko on a Hetzner machine
        install = {
          type = "app";
          program = nixpkgs.lib.getExe (
            pkgs.writeShellApplication {
              name = "install-vps";
              runtimeInputs = with pkgs; [
                nixos-anywhere
                sops
                coreutils
              ];
              text = ''
                target=''${1:-}
                if [ -z "$target" ]; then
                  echo "usage: nix run .#install -- root@<host>" >&2
                  exit 64
                fi

                key="''${SOPS_AGE_KEY_FILE:-$HOME/.sops-nix/key.txt}"
                if [ ! -f "$key" ]; then
                  echo "no age key at $key (set SOPS_AGE_KEY_FILE)" >&2
                  exit 1
                fi

                # Fail here, not mid-install, if this key cannot read the secrets.
                if ! SOPS_AGE_KEY_FILE="$key" sops -d --extract '["email"]["postmaster"]' \
                     secrets.yaml >/dev/null 2>&1; then
                  echo "$key does not decrypt secrets.yaml — the installed host would have no credentials" >&2
                  exit 1
                fi
                echo "age key verified against secrets.yaml"

                stage=$(mktemp -d)
                trap 'rm -rf "$stage"' EXIT
                install -d -m 0755 "$stage/var/lib/sops-nix"
                install -m 0600 "$key" "$stage/var/lib/sops-nix/key.txt"

                exec nixos-anywhere \
                  --flake ".#vps-hetzner" \
                  --target-host "$target" \
                  --extra-files "$stage" \
                  "''${@:2}"
              '';
            }
          );
        };

        default = {
          type = "app";
          program = nixpkgs.lib.getExe (
            pkgs.writeShellApplication {
              name = "run-vm";
              runtimeInputs = with pkgs; [ coreutils ];
              text = ''
                SOPS_KEY_DIR=$(mktemp -d)
                trap 'rm -rf "$SOPS_KEY_DIR"' EXIT
                install -m 0600 "$HOME/.sops-nix/key.txt" "$SOPS_KEY_DIR/key.txt"
                export SOPS_KEY_DIR
                exec ${vps.config.system.build.vmWithDisko}/bin/disko-vm "$@"
              '';
            }
          );
        };
      };
    };
}
