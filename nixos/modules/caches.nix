/**
  MeshOS - Copyright (C) 2024+ MeshOS Contributors
  SPDX-License-Identifier: LGPL-3.0-or-later
  Authors:
    Andrew Brooks <andrewgrantbrooks@gmail.com>
    Morgan Jones <me@numin.it>
*/

{ ... }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) types;
  inherit (lib.modules)
    mkIf
    mkMerge
    mkForce
    mkAfter
    mkDefault
    ;
  inherit (lib.options) mkOption;
  inherit (lib.lists)
    singleton
    optional
    filter
    length
    head
    ;
  inherit (lib.attrsets) attrNames;
  inherit (lib.strings) match;

  cfg = config.networking.mesh.cache;
  plan = config.networking.mesh.plan;
  hostCfg = plan.hosts.${config.networking.hostName};
in
{
  options = {
    networking.mesh.cache = {
      server = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            When true, stands up ncpr listening on all addresses.

            This allows other mesh peers to download store paths from you,
            potentially avoiding rebuilds or downloads that will be bottlenecked on
            slower connections.
          '';
        };
      };

      client = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Configure Nix to connect to all other declared mesh stores.
          '';
        };
        useHydra = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Configure Nix to connect to and trust https://cache.nixos.org. Default is true.
          '';
        };
        trustHydra = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Configure Nix to trust https://cache.nixos.org. Default is true.
          '';
        };
        useRecommendedCacheSettings = mkOption {
          default = false;
          type = types.bool;
          description = ''
            When true, decreases the Nix daemon's max download retries and download timeout,
            and allows Nix to recover from a failed download. Also enables builders-use-substitutes
            since remote builders will likely have faster connections than us.
          '';
        };
      };
    };
  };

  config =
    let
      recommended = x: mkIf (cfg.client.enable && cfg.client.useRecommendedCacheSettings) (mkDefault x);
      myWifiAddress = hostCfg.wifi.address or null;
      myNebulaAddress = hostCfg.nebula.address or null;
      myListenAddresses =
        optional (myWifiAddress != null) myWifiAddress
        ++ optional (myNebulaAddress != null) myNebulaAddress;
      otherMeshCacheURLs =
        let
          isNotMe =
            url:
            let
              matches = match "https?://([^:]+)(:[0-9]+)?.*" url;
              matched = matches != null && length matches == 2;
            in
            matched -> (head matches != myWifiAddress && head matches != myNebulaAddress);
        in
        filter isNotMe (plan.nix.cacheURLs hostCfg.cache.client.sets);
      allMeshCachePubkeys = plan.nix.cachePubkeys hostCfg.cache.client.sets;
      builders = plan.nix.builders hostCfg.build.client.sets;
      hasBuilders = length (attrNames builders) > 0;
    in
    {
      nix = {
        settings = {
          builders-use-substitutes = recommended true;
          keep-going = recommended true;
          download-attempts = recommended 2;
          fallback = recommended true;
          connect-timeout = recommended 3;
          substituters = mkMerge [
            (mkIf (cfg.client.enable && !cfg.server.enable) (
              otherMeshCacheURLs ++ optional cfg.client.useHydra "https://cache.nixos.org?priority=10"
            ))
            (mkIf (cfg.client.enable && cfg.server.enable) (mkForce [
              "${if hostCfg.cache.server.secure then "https" else "http"}://${
                if hostCfg.cache.server.hostOverride == null then "localhost" else hostCfg.cache.server.hostOverride
              }:${toString hostCfg.cache.server.port}"
            ]))
          ];
          trusted-public-keys = mkIf ((!cfg.client.useHydra) && (!cfg.client.trustHydra)) (mkForce [ ]);
          extra-trusted-public-keys = mkIf cfg.client.enable allMeshCachePubkeys;
        };
      };
      networking.firewall = mkMerge [
        (mkIf cfg.server.enable { allowedTCPPorts = mkAfter (singleton hostCfg.cache.server.port); })
      ];
      services = mkMerge [
        (mkIf cfg.server.enable {
          ncps = {
            enable = true;
            server = {
              addr = ":${toString hostCfg.cache.server.port}";
            };
            upstream = {
              caches = otherMeshCacheURLs ++ optional cfg.client.useHydra "https://cache.nixos.org?priority=10";
              publicKeys =
                config.nix.settings.trusted-public-keys or [ ]
                ++ config.nix.settings.extra-trusted-public-keys or [ ];
            };
            cache = {
              inherit (config.networking) hostName;
            };
          };
        })
        (mkIf cfg.server.enable { openssh.enable = mkForce true; })
      ];
      systemd = mkMerge [
        (mkIf cfg.server.enable {
          services.ncps = {
            serviceConfig.Restart = mkForce "always";
            unitConfig.StartLimitIntervalSec = mkForce 10;
          };
        })
      ];
    };
}
