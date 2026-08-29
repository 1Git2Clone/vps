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
          activationTimeout = 300;
        };
      };

      checks = builtins.mapAttrs (_system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;

      devShells.${system} = {
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
            deploy-rs.packages.${system}.default
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
      };

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
