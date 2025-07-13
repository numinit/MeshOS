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
  pkgs,
  lib,
  ...
}:

let
  inherit (lib) types;
  inherit (lib.options) mkOption;
  inherit (lib.modules) mkIf;
  inherit (lib.lists) head tail length;
  inherit (lib.attrsets) genAttrs;
  cfg = config.networking.mesh.wifi;
  plan = config.networking.mesh.plan;
  hostCfg = plan.hosts.${config.networking.hostName};
in
{
  options = {
    networking.mesh.wifi.enable = mkOption {
      default = cfg.dedicatedWifiDevices != [ ];
      type = types.bool;
      description = ''
        Set to true to join the mesh network (or just specify some dedicatedWifiDevices).
      '';
    };
    networking.mesh.wifi.countryCode = mkOption {
      type = types.str;
      description = ''
        The wireless country code. Must be specified in order to start wpa_supplicant.
      '';
    };
    networking.mesh.wifi.dedicatedWifiDevices = mkOption {
      default = [ ];
      type = with types; listOf str;
      description = ''
        Names of the network interfaces to use to connect to the mesh.
        Note that these are _dedicated_ devices. You will be unable to
        manage them with networkmanager and probably shouldn't try to use them
        for other purposes.

        Each device will be tuned to a single channel, alternating between
        primary and secondary channels in the order that the devices appear
        in the list.
      '';
    };
    networking.mesh.wifi.sharedInternetDevice = mkOption {
      default = null;
      type = with types; nullOr str;
      description = ''
        When set, shares the internet connection from the specified device to any BATMAN
        mesh clients looking for one.
      '';
    };
    networking.mesh.wifi.advertisedUploadMbps = mkOption {
      default = 20;
      type = types.int;
      description = ''
        Upload bandwidth, in megabits per second (base 1000), advertised to mesh peers
        looking to connect to the internet through the mesh. BATMAN considers this
        information when making routing decisions.

        The default is 20 Mbps, based on observed peak upload speeds through a shitty LTE
        modem (a Sierra Wireless EM7455).

        If not sharing your internet connection via `sharedInternetDevice`, this option has no effect.
      '';
    };
    networking.mesh.wifi.advertisedDownloadMbps = mkOption {
      default = 30;
      type = types.int;
      description = ''
        Download bandwidth, in megabits per second (base 1000), advertised to mesh peers
        looking to connect to the internet through the mesh. BATMAN considers this
        information when making routing decisions.

        The default is 30 Mbps, based on observed peak download speeds through a shitty LTE
        modem (a Sierra Wireless EM7455).

        If not sharing your internet connection via `sharedInternetDevice`, this option has no effect.
      '';
    };
    networking.mesh.wifi.useForFallbackInternetAccess = mkOption {
      default = true;
      type = types.bool;
      description = ''
        Attempt to access the internet through the mesh. Obviously, this requires
        that at least one reachable mesh peer is sharing an internet connection
        (see `sharedInternetDevice`).

        This will create a route to 0.0.0.0 with a high metric ("low priority"),
        causing manually-created routes (like those created by NetworkManager) to
        take precedence when available.
      '';
    };
  };

  config = mkIf cfg.enable {
    networking.mesh.ieee80211s = {
      enable = true;
      country = cfg.countryCode;
      exitDevice = cfg.sharedInternetDevice;
      uploadMbps = cfg.advertisedUploadMbps;
      downloadMbps = cfg.advertisedDownloadMbps;
      networks.mesh2 = {
        aqm.enable = true;
        addressAndMask = hostCfg.wifi.address;
        routeToExits = cfg.useForFallbackInternetAccess;
        devices =
          let
            inherit (plan.constants) wifi;
            bucket =
              devlist:
              let
                go =
                  devs: lastWasPrimary: acc:
                  if length devs == 0 then
                    acc
                  else
                    let
                      kind = if lastWasPrimary then "secondary" else "primary";
                    in
                    go (tail devs) (!lastWasPrimary) (acc // { ${kind} = (acc.${kind} or [ ]) ++ [ (head devs) ]; });
              in
              go devlist false { };
            setupOnChannel = channel: dev: {
              inherit channel;
              inherit (wifi) essid passwordFile;
            };
            bucketed = bucket cfg.dedicatedWifiDevices;
          in
          (genAttrs (bucketed.primary or [ ]) (setupOnChannel wifi.primaryChannel))
          // (genAttrs (bucketed.secondary or [ ]) (setupOnChannel wifi.secondaryChannel));
      };
    };
  };
}
