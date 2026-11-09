{
  description = "Nix packaging for Reactive Resume — a free, open-source resume builder (amruthpillai/Reactive-Resume)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Build-time only: fetchPnpmDeps + pnpmConfigHook that understand pnpm 12
    # (fetcherVersion 5, the v11 SQLite store index). Deliberately NOT meant to
    # follow the consumer's nixpkgs: the pnpmDeps FOD hash depends on the fetcher's
    # nixpkgs, so pinning it here gives every consumer (nic-os included) the hash
    # this repo computed. Nothing from it reaches the runtime closure.
    nixpkgs-pnpm.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { self, nixpkgs, flake-parts, ... }:
    let
      pnpmPkgsFor = system: inputs.nixpkgs-pnpm.legacyPackages.${system};
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      perSystem = { pkgs, system, ... }:
        let
          reactive-resume = pkgs.callPackage ./package.nix { pnpmPkgs = pnpmPkgsFor system; };
        in {
          packages.reactive-resume = reactive-resume;
          packages.default         = reactive-resume;
        };

      flake = {
        nixosModules.reactive-resume = import ./module.nix { inherit self pnpmPkgsFor; };
        nixosModules.default         = self.nixosModules.reactive-resume;

        # Overlay exposing `pkgs.reactive-resume`
        overlays.default = final: prev: {
          reactive-resume = final.callPackage ./package.nix {
            pnpmPkgs = pnpmPkgsFor final.stdenv.hostPlatform.system;
          };
        };
      };
    };
}
