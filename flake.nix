{
  description = "Fetch derivations from your friends.";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkcs = {
      url = "github:numinit/nixpkcs/v1.2";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
      };
    };
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkcs,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
      ];

      flake = {
        version = "0.6.0";

        # MeshOS releases are named after mountains.
        release = "Big Bear";

        nixosModules.default = import ./nixos/modules inputs;
      };

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          config,
          system,
          inputs',
          pkgs,
          final,
          lib,
          ...
        }:
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [
              self.overlays.default
              nixpkcs.overlays.default
            ];
            config = { };
          };

          overlayAttrs = {
            # nothing
          };

          checks = {
            test = pkgs.callPackage ./nixos/tests/meshos.nix {
              inherit self;
              extraMachineOptions =
                { config, ... }:
                {
                  virtualisation.tpm.enable = true;
                  nixpkcs.tpm2.enable = true;
                };
            };
          };
        };
    };
}
