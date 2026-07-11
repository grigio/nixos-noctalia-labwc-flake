{
  description = "NixOS configuration — labwc + Noctalia desktop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    noctalia.url = "github:noctalia-dev/noctalia/cachix";
    noctalia-labwc-color-sync = {
      url = "github:grigio/noctalia-labwc-color-sync";
      flake = false;
    };
  };

  nixConfig = {
    extra-trusted-substituters = [ "https://noctalia.cachix.org" ];
    extra-trusted-public-keys = [ "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4=" ];
  };

  outputs = { self, nixpkgs, noctalia, noctalia-labwc-color-sync, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        noctalia.nixosModules.default
        ({ pkgs, ... }: {
          environment.systemPackages = [ (pkgs.callPackage noctalia-labwc-color-sync {}) ];
        })
      ];
    };

    formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixpkgs-fmt;

    devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {
      name = "nixos-flake";
      buildInputs = with nixpkgs.legacyPackages.x86_64-linux; [
        nixpkgs-fmt
        nixos-rebuild
      ];
    };
  };
}
