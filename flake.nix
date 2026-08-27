{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      sops-nix,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          nixd
          nixpkgs-fmt
          statix
          sops
          age
          # Add any other tools you need
        ];
      };

      nixosConfigurations.vps = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./configuration.nix
          sops-nix.nixosModules.sops
        ];
      };

      packages.${system}.default = self.nixosConfigurations.vps.config.system.build.images.raw-efi;
    };
}
