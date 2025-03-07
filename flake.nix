{
  description = "Fetch derivations from your friends.";
  inputs = {
    nixpkgs.url = "github:numinit/nixpkgs/kismet/add-module";
    nixpkcs = {
      url = "github:numinit/nixpkcs/v1.1";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
      };
    };
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
    flake-parts.url = "github:hercules-ci/flake-parts";
    mediatek-fw = {
      url = "github:openwrt/mt76";
      flake = false;
    };
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
        version = "0.5.0";

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
            tpm2-pkcs11 = pkgs.tpm2-pkcs11.override {
              abrmdSupport = true;
            };
            ncps = pkgs.ncps.overrideAttrs (prevPkg: {
              # Need to patch this to avoid a crash with how we're using ncps.
              patches = prevPkg.patches or [ ] ++ [
                (pkgs.fetchpatch {
                  url = "https://github.com/kalbasit/ncps/pull/193.patch";
                  hash = "sha256-AAsBplZLKptnEI1SglUwOyqOOlpJ5+3cD3kmwN4h9V8=";
                })
              ];
            });
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
