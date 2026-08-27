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
  };

  outputs =
    {
      nixpkgs,
      disko,
      sops-nix,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      vps = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./configuration.nix
          ./disk-config.nix
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
        ];
      };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          nixd
          nixpkgs-fmt
          statix
          sops
          age
          ssh-to-age
          nixos-anywhere
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
