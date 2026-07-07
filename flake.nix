{
  description = "Nix packaging for Reactive Resume — a free, open-source resume builder (amruthpillai/Reactive-Resume)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { self, nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      perSystem = { pkgs, system, ... }:
        let reactive-resume = pkgs.callPackage ./package.nix { }; in {
          packages.reactive-resume = reactive-resume;
          packages.default         = reactive-resume;
        };

      flake = {
        nixosModules.reactive-resume = import ./module.nix self;
        nixosModules.default         = self.nixosModules.reactive-resume;

        # Overlay exposing `pkgs.reactive-resume`
        overlays.default = final: prev: {
          reactive-resume = final.callPackage ./package.nix { };
        };
      };
    };
}
