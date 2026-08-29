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
        # The MagicDNS name, not an IP: this survives the primary-IP swap during
        # the migration, so the same command works before and after cutover.
        hostname = "hu-tao";

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

      devShells.${system}.default = pkgs.mkShell {
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
          opentofu
          deploy-rs.packages.${system}.default
        ];
      };

      packages.${system}.default = vps.config.system.build.toplevel;
      apps.${system} = {
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
