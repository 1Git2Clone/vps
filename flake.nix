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

      # ── The CI runner ──────────────────────────────────────────────────────
      # A second system in the same flake rather than a second flake, because
      # it shares boot, hardware, nix, security and disk-config verbatim — see
      # runner/configuration.nix for the list it deliberately does NOT share.
      #
      # NOTE THE ABSENT ARGUMENT: sops-nix.nixosModules.sops is in mkVps and is
      # not here. This host holds no age key and can decrypt nothing in
      # secrets.yaml, so the module would only add a unit that fails at boot.
      # Task: keep it absent. checks.runner-has-no-secrets asserts it.
      mkRunner =
        extraModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./runner/configuration.nix
            ./disk-config.nix
            disko.nixosModules.disko
          ]
          ++ extraModules;
        };

      # Same one-line difference as vps-hetzner: Hetzner presents the root disk
      # as /dev/sda, and disk-config.nix defaults to /dev/vda for the local VM.
      # The 80 GB is picked up without a line changing — the root partition is
      # size = "100%".
      runner-hetzner = mkRunner [
        { disko.devices.disk.main.device = "/dev/sda"; }
      ];
    in
    {
      nixosConfigurations = {
        inherit vps vps-hetzner runner-hetzner;
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
      # ONE attrset rather than `deploy.nodes.vps` plus a generated sibling:
      # Nix cannot merge an assignment to `deploy.nodes` with an assignment to
      # `deploy.nodes.vps` in the same set, and the runners have to be generated
      # rather than written out.
      deploy.nodes = {
        vps = {
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
            # (10min, in modules/containers/serenity-bot.nix). That unit only
            # covers the boot path now, but an overrun there should still read as
            # "serenity-bot-image.service: Start operation timed out" rather than
            # an unexplained rollback. Keep the ordering if either number moves.
            #
            # This timeout is what bounds the build on a DEPLOY, because the build
            # happens in the activation script itself — deliberately, since that
            # is the one phase of a switch where the old container is still
            # serving (see the phase list in modules/containers/serenity-bot.nix).
            # Activation therefore still WAITS for the compile, which is why this
            # number stays where it is; the bot just does not go down for it.
            #
            # The cost is still borne by every deploy, so the durable fix stands:
            # build the image off-box — same architecture, so a native build here
            # and a pushed closure there, not a cross-compile — and ship it as an
            # imageFile so activation only does `docker load`.
            activationTimeout = 900;
          };
        };
      }
      # The runners, one node each, generated from the same infra.runnerIPv4s
      # the VPS firewall is built from — so a runner that exists is a runner you
      # can deploy to, with no second list to keep in step. They are
      # interchangeable machines running the identical closure; only the address
      # differs.
      #
      # MAGIC ROLLBACK MATTERS MORE HERE THAN ON THE VPS. A runner is reachable
      # only by `ssh -J vps`, across two firewalls and the jump host's own
      # policy-drop output chain — there is no tailnet fallback and no second
      # route in. A bad rule in modules/runner/firewall.nix locks the box out
      # for good, and recovery is the Hetzner web console. This is the control
      # that makes editing that file a normal thing to do rather than a gamble.
      // nixpkgs.lib.mapAttrs' (
        name: addr:
        nixpkgs.lib.nameValuePair "runner-${name}" {
          hostname = addr;

          profiles.system = {
            sshUser = "root";
            user = "root";
            path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.runner-hetzner;

            # Through the VPS: the runner's single ingress rule is tcp/22 from
            # 167.233.24.58/32 and nothing else. The jump host's output chain
            # has to permit it too — that is what infra.runnerIPv4s feeds.
            sshOpts = [
              "-o"
              "ProxyJump=vps"
            ];

            magicRollback = true;
            autoRollback = true;

            # No containers to recreate and no image build during activation,
            # unlike the VPS: this box's activation is a systemd reload and a
            # ruleset swap. The defaults would do; these are headroom for a slow
            # link through the jump.
            confirmTimeout = 120;
            activationTimeout = 240;
          };
        }
      ) self.nixosConfigurations.runner-hetzner.config.infra.runnerIPv4s;

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

              # Makes good on the mkRunner comment above ("Task: keep it absent.
              # checks.runner-has-no-secrets asserts it"). The runner holds no age
              # key, so a sops-install-secrets unit appearing on it is a build that
              # must fail, not a build that boots with dead credentials.
              #
              # Reads systemd.services on the EVALUATED config, not the built
              # closure — attribute access is lazy, so this never forces
              # system.build.toplevel. That distinction is the whole lesson in the
              # deploy-schema comment above: deploy-schema looked cheap and instead
              # compiled deploy-rs from source because a context-bearing string
              # dragged the closure in. `hasSecrets` here is a plain Nix bool with
              # no derivation attached, so the runCommand below builds nothing but
              # itself either way.
              runner-has-no-secrets =
                let
                  units = self.nixosConfigurations.runner-hetzner.config.systemd.services;
                  hasSecrets = builtins.hasAttr "sops-install-secrets" units;
                  script =
                    if hasSecrets then
                      ''
                        echo "runner-hetzner grew a sops-install-secrets unit; this host holds no age key" >&2
                        exit 1
                      ''
                    else
                      "touch $out";
                in
                pkgs.runCommand "runner-has-no-secrets" { } script;

              # The one-way rule, proven rather than asserted. See the header of
              # tests/runner-firewall.nix — the property it protects is rule
              # ORDER in two nftables chains, which review cannot see and which
              # fails silently.
              #
              # HAND-RUN ONLY, NOT IN CI: `nix build
              # .#checks.x86_64-linux.runner-firewall -L`, and it needs a host
              # with /dev/kvm. It is not in the build step of
              # .forgejo/workflows/ci.yml or .github/workflows/ci.yml — that
              # runner is a shared-vCPU Hetzner box with no nested
              # virtualisation, so a two-node NixOS VM test there falls back to
              # qemu's TCG software emulation. Measured locally 2026-09-19:
              # booting these same two nodes to multi-user (nothing else) took
              # 20s under KVM and 1m40s under a forced-TCG run — 5x just to
              # boot, before either behavioural subtest runs a single `nc`.
              # That is not a per-push cost this repo's CI box should carry.
              # `runner-firewall-ordering` below is the automated stand-in: it
              # cannot prove the kernel enforces the order, only that the text
              # is ordered correctly, which is why this check still exists for
              # a human to run before trusting a change to firewall.nix.
              runner-firewall = import ./tests/runner-firewall.nix {
                inherit nixpkgs system;
              };

              # The static, CI-run counterpart to runner-firewall above. It
              # cannot prove the kernel enforces the one-way rule — only a
              # booted VM sending real packets can, which is what
              # runner-firewall is for — but it catches the exact regression
              # that check exists for (the VPS rules sinking below a broad
              # accept) by grepping the EVALUATED ruleset for line order, needs
              # no KVM, and builds in seconds. Wired into
              # .forgejo/workflows/ci.yml's build step, so a reordering is
              # caught on every push rather than only when someone remembers
              # to hand-run the VM test.
              #
              # `ruleset` is a plain Nix string built from config values
              # (infra.publicIPv4, infra.cacheProxyPort, a literal /64) with no
              # package or derivation spliced in — confirmed with
              # `builtins.hasContext` returning false — so writing it out with
              # writeText does not drag in a closure the way deploy.json did
              # above; nothing here is realised beyond this tiny derivation and
              # the coreutils/gnugrep already in the closure.
              #
              # Anchored on the named counters and the literal accept lines
              # rather than on infra.publicIPv4's value, so the pattern does
              # not have to track the real address and stays meaningful against
              # the test override in tests/runner-firewall.nix too. Every
              # pattern is required to match EXACTLY ONCE, not just "at
              # least once" — a rule that was renamed or deleted exits 1
              # rather than silently comparing nothing, which would otherwise
              # make "the rules are missing" look identical to "the rules are
              # correctly ordered".
              #
              # Exactly-once is load-bearing, not belt-and-braces: a fix-round
              # review found `counter name vps_blocked_fwd` also matching
              # `counter name vps_blocked_fwd6` (same for _out), so deleting
              # the v4 forward drop rule outright left the pattern satisfied by
              # its v6 sibling and this check went GREEN over a deleted rule —
              # the exact vacuous-pass class this check exists to prevent,
              # relocated from comments (round 1's false positive) to a
              # same-prefix sibling rule. Fixed two ways: the four
              # `counter name vps_*` patterns below are anchored with a
              # trailing space so `vps_blocked_fwd ` cannot match
              # `vps_blocked_fwd6` (no `6` variant exists for the two
              # `_allowed_*` counters today, but nothing stops one being added
              # later, so all four got the anchor rather than only the two
              # currently ambiguous); and `line()` itself now rejects ANY
              # pattern matching more than once, so a future ambiguity this
              # review did not think of fails loudly instead of silently
              # picking a line.
              runner-firewall-ordering =
                let
                  ruleset = self.nixosConfigurations.runner-hetzner.config.networking.nftables.ruleset;
                  rulesetFile = pkgs.writeText "runner-nftables-ruleset.nft" ruleset;
                in
                pkgs.runCommand "runner-firewall-ordering" { } ''
                  set -euo pipefail

                  # firewall.nix's ruleset string carries its own `#` nft
                  # comments (e.g. "`iifname \"podman*\" accept`, for the same
                  # first-match reason"), and one of them literally quotes a
                  # pattern this check greps for — a real false-positive found
                  # while writing this, not a hypothetical. Blank full-line
                  # comments (keep the line so numbers still line up with the
                  # original file) before searching, so a comment can never be
                  # mistaken for the rule it is describing.
                  clean=$(mktemp)
                  sed -E 's/^([[:space:]]*)#.*/\1/' ${rulesetFile} > "$clean"

                  # Prints the one matching line number. Fails loudly — never
                  # silently — both when the pattern is absent (renamed or
                  # deleted) and when it matches more than once: an ambiguous
                  # pattern is exactly how a deleted vps_blocked_fwd rule once
                  # passed this check by having vps_blocked_fwd6 answer for it,
                  # so "matches something" is not enough, it must match
                  # exactly the one line it is meant to identify.
                  line() {
                    local pattern=$1
                    local matches count n
                    matches=$(grep -nF -- "$pattern" "$clean") || true
                    count=$(printf '%s\n' "$matches" | grep -c . || true)
                    if [ "$count" -eq 0 ]; then
                      echo "runner-firewall-ordering: pattern not found (renamed or deleted?): $pattern" >&2
                      exit 1
                    fi
                    if [ "$count" -gt 1 ]; then
                      echo "runner-firewall-ordering: pattern matched $count lines, expected exactly 1 (tighten it so it identifies one rule): $pattern" >&2
                      echo "$matches" >&2
                      exit 1
                    fi
                    n=$(printf '%s\n' "$matches" | cut -d: -f1)
                    echo "$n"
                  }

                  # Trailing space on the four counter-name patterns: without
                  # it, "vps_blocked_fwd" is a PREFIX of "vps_blocked_fwd6"
                  # and grep -F matches it there too — see the comment above.
                  allowed_out=$(line 'counter name vps_allowed_out ')
                  blocked_out=$(line 'counter name vps_blocked_out ')
                  podman_out=$(line 'oifname "podman*" accept')
                  portlist_out=$(line 'tcp dport { 53, 80, 443 }')

                  allowed_fwd=$(line 'counter name vps_allowed_fwd ')
                  blocked_fwd=$(line 'counter name vps_blocked_fwd ')
                  podman_fwd=$(line 'iifname "podman*" accept')

                  fail=0
                  above() {
                    local vpsLine=$1 broadLine=$2 chain=$3 broadName=$4
                    if [ "$vpsLine" -ge "$broadLine" ]; then
                      echo "runner-firewall-ordering: $chain chain: line $vpsLine does not sit above line $broadLine ($broadName) — the VPS rule and $broadName are in the wrong order" >&2
                      fail=1
                    fi
                  }

                  above "$allowed_out" "$podman_out" output 'oifname "podman*" accept'
                  above "$blocked_out" "$podman_out" output 'oifname "podman*" accept'
                  above "$allowed_out" "$portlist_out" output 'the port allow-list'
                  above "$blocked_out" "$portlist_out" output 'the port allow-list'
                  above "$allowed_fwd" "$podman_fwd" forward 'iifname "podman*" accept'
                  above "$blocked_fwd" "$podman_fwd" forward 'iifname "podman*" accept'

                  [ "$fail" -eq 0 ] || exit 1
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
              markdownlint-cli2
              # The handbook in docs/. mdbook-mermaid is the preprocessor that
              # turns a ```mermaid fence into a rendered diagram; without it
              # the fence ships as a code block. See docs/book.toml.
              mdbook
              mdbook-mermaid
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
              markdownlint-cli2
              mdbook
              mdbook-mermaid
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
        # ── The handbook, served locally ───────────────────────────────────────
        #   nix run .#docs
        #
        # Two commands rather than one, and the first is the one that is easy
        # to forget: `mdbook-mermaid install` writes mermaid.min.js and
        # mermaid-init.js next to docs/book.toml, which references them in
        # `additional-js`. Those files are gitignored — 2.6 MB of vendored
        # minified JS whose version is already pinned by this flake.lock — so a
        # fresh clone does not have them and `mdbook build` fails outright on
        # the missing paths.
        #
        # Wrapping it is worth the lines because the failure is confusing in
        # exactly the wrong way: the error names a file nobody wrote, in a
        # directory that looks complete.
        docs = {
          type = "app";
          program = nixpkgs.lib.getExe (
            pkgs.writeShellApplication {
              name = "serve-docs";
              runtimeInputs = with pkgs; [
                mdbook
                mdbook-mermaid
              ];
              text = ''
                cd "''${MDBOOK_ROOT:-.}"
                mdbook-mermaid install docs
                exec mdbook serve docs "$@"
              '';
            }
          );
        };

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
