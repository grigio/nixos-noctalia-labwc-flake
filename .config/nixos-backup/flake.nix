{
  description = "NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs, ... }: let
    pkgsFor = nixpkgs.legacyPackages.x86_64-linux;
  in {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
      ];
    };

    devShells.x86_64-linux.default = pkgsFor.mkShell {
      packages = with pkgsFor; [
        deadnix
        statix
      ];
    };
  };
}
