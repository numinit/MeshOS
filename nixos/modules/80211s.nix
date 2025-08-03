/**
  MeshOS - Copyright (C) 2024+ MeshOS Contributors
  SPDX-License-Identifier: LGPL-3.0-or-later
  Authors:
    Andrew Brooks <andrewgrantbrooks@gmail.com>
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
  inherit (types) attrsOf submodule;
  inherit (lib.options) mkOption;
  inherit (lib.modules) mkAfter mkIf;
  inherit (lib.strings) escapeShellArg optionalString concatStringsSep;
  inherit (lib.lists)
    concatMap
    allUnique
    intersectLists
    elem
    ;
  inherit (lib.attrsets)
    genAttrs
    attrNames
    attrValues
    listToAttrs
    mapAttrs'
    mergeAttrsList
    ;

  cfg = config.networking.mesh.ieee80211s;
in
{
  options = {
    networking.mesh.ieee80211s = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Set to true to enable all networks defined under `networking.mesh.ieee80211s.networks`.
        '';
      };
      country = mkOption {
        type = types.str;
        description = ''
          Regulatory domain to use. This determines which channels are usable by mesh devices.
          Defaults to `US`.

          Take care to set this appropriately if you use networking.mesh.ieee80211s outside the US;
          interfering with coastal radar systems can be a career-limiting move.
        '';
      };
      exitDevice = mkOption {
        type = with types; nullOr str;
        default = null;
        description = ''
          When set, the specified netdev will be used to provide internet access to other
          clients on the mesh.

          Providing a non-null value places the BATMAN device into "server" gateway mode,
          informing mesh peers that this system is sharing its internet connection. It
          also sets up an nftables masquerade rule for outbound connections.

          If unset, this system will not share its internet connection.
        '';
      };
      uploadMbps = mkOption {
        type = with types; nullOr int;
        default = null;
        description = ''
          When set, advertise this upload rate (in megabits per second, base 1000) to clients
          looking for a connection. You should specify the typical available upload bandwidth
          on `networking.mesh.ieee80211s.exitDevice`.

          If `networking.mesh.ieee80211s.exitDevice` is not set, this option has no effect.

          If unset, BATMAN's defaults are used.
        '';
      };
      downloadMbps = mkOption {
        type = with types; nullOr int;
        default = null;
        description = ''
          When set, advertise this download rate (in megabits per second, base 1000) to clients
          looking for a connection. You should specify the typical available download bandwidth
          on `networking.mesh.ieee80211s.exitDevice`.

          If `networking.mesh.ieee80211s.exitDevice` is not set, this option has no effect.

          If unset, BATMAN's defaults are used.
        '';
      };
      networks = mkOption {
        description = ''
          All mesh networks to create. The names of each BATMAN network device are
          given by the attribute names you specify.
        '';
        default = { };
        type = attrsOf (submodule {
          options = {
            addressAndMask = mkOption {
              type = types.str;
              description = ''
                Static IPv4 address and subnet mask to assign to the mesh interface.
              '';
            };
            routeToExits = mkOption {
              type = types.bool;
              default = false;
              description = ''
                When set to true, the system will try to connect to the internet through the mesh.
                This requires that at least one reachable node in the mesh is running in gateway
                mode and sharing its connection.
              '';
            };
            metric = {
              type = types.int;
              default = 666;
              description = ''
                The metric. Set to something low by default so Network Manager takes priority. If you
                are using scripted networking, try something higher.
              '';
            };
            aqm = {
              enable = mkOption {
                description = ''
                  Enables a [`tc-cake`](https://www.man7.org/linux/man-pages/man8/tc-cake.8.html) qdisc
                  on the BATMAN netdev. Among other things, this can dramatically improve the
                  network's bufferbloat characteristics (ie, it will stay responsive even when
                  operating at high throughput).

                  The defaults are intended for a typical mesh LAN that can push a quarter gigabit between
                  nodes, but shouldn't be a liability in the general case.
                '';
                type = types.bool;
                default = true;
              };
              roundTripMillisec = mkOption {
                description = ''
                  Rough estimated typical-case round-trip time, in milliseconds, for connections on the mesh.
                  Defaults to 20ms.
                '';
                type = types.ints.positive;
                default = 20;
              };
              bandwidthMbps = mkOption {
                description = ''
                  Rough estimated best-case bandwidth across a mesh link, in Mbps.
                  If unsure, guess high -- setting this too low can throttle bandwidth.

                  Defaults to 250, based on estimates from iperf2 between two line-of-sight Panda
                  PAU0Ds.
                '';
                type = types.ints.positive;
                default = 250;
              };
            };
            devices = mkOption {
              description = ''
                Each BATMAN mesh needs one or more dedicated WiFi devices to run on top of.
                Configure each here, making sure that each network interface name matches the
                attribute name.
              '';
              type = attrsOf (submodule {
                options = {
                  channel = mkOption {
                    type = types.int;
                    description = ''
                      Frequency, in MHz, on which the wireless device should operate.
                      To determine which your hardware supports, run `iw phy`.

                      It's recommended to avoid frequencies that `iw phy` marks "no IR"
                      because it will prevent creating a mesh-point when no established ones are
                      reachable.
                    '';
                  };
                  essid = mkOption {
                    type = types.str;
                    description = ''
                      The mesh ID to join or create.
                    '';
                  };
                  passwordFile = mkOption {
                    type = types.path;
                    description = ''
                      The file containing the password to use for the mesh network.
                    '';
                  };
                };
              });
            };
          };
        });
      };
    };
  };

  config = mkIf cfg.enable (
    let
      batmanDevices = attrNames cfg.networks;
      wifiDevices = concatMap (batdev: attrNames cfg.networks.${batdev}.devices) batmanDevices;
      wirelessTxQueueLen = 32;

      defineLinksFor =
        batdev:
        let
          # XXX: systemd's default link config, 99-default.link, will match if we
          # don't make ours alphabetically earlier. Stick a "10-" at the front of any
          # .link file names.
          prioritizeLinkConfig = wifidev: link: {
            name = "10-${wifidev}";
            value = link;
          };
          linkConfigs =
            (genAttrs (attrNames cfg.networks.${batdev}.devices) (wifidev: {
              matchConfig.OriginalName = wifidev;
              linkConfig = {
                # WiFi devs have beefy internal buffers (the Panda PAU0D buffers about 1000 packets at our
                # MTU, going by the mean ping time elevation in a maximum throughput state).
                # Don't exacerbate bufferbloat by adding Linux's giant default buffer size.
                # On a fresh boot, we wouldn't expect this to be a problem (this device should
                # use the "noqueue" qdisc), but we're being paranoid in case a qdisc that cares
                # about this were added externally.
                TransmitQueueLength = wirelessTxQueueLen;
                NamePolicy = "keep kernel database onboard slot path";
                AlternativeNamesPolicy = "database onboard slot path";
                # Wouldn't recommend changing this: BATMAN gateway announcements linger for a long
                # time. If you're sharing your internet connection and one of your BATMAN WiFi devices
                # craps out momentarily, re-joining the mesh with the same MAC allows peers using
                # your internet connection to recover more quickly. Otherwise, they'd have to wait on
                # BATMAN's throughput estimation to penalize your previous MAC enough to push them
                # onto an alternative gateway.
                MACAddressPolicy = "persistent";
              };
            }))
            // {
              ${batdev} = {
                matchConfig.OriginalName = batdev;
                # pretty sure CAKE doesn't give a damn about this, but the user might disable AQM
                linkConfig.TransmitQueueLength = wirelessTxQueueLen;
              };
            };
        in
        mapAttrs' prioritizeLinkConfig linkConfigs;
      defineNetworksFor =
        batdev:
        (genAttrs (attrNames cfg.networks.${batdev}.devices) (wifidev: {
          name = wifidev;
          linkConfig = {
            MTUBytes = "1532";
            ActivationPolicy = "always-up";
            RequiredForOnline = "no";
            ARP = "no";
          };
          networkConfig = {
            BatmanAdvanced = batdev;
            LinkLocalAddressing = "no";
            IgnoreCarrierLoss = "yes";
            LLMNR = "no";
            DHCP = "no";
          };
        }))
        // {
          ${batdev} = {
            name = batdev;
            address = [ cfg.networks.${batdev}.addressAndMask ];
            linkConfig = {
              MTUBytes = "1500";
              ActivationPolicy = "always-up";
              RequiredForOnline = "no";
            };
            networkConfig = {
              MulticastDNS = "yes";
              IgnoreCarrierLoss = "yes";
              IPMasquerade = mkIf (cfg.exitDevice != null) "ipv4";
              IPv4ProxyARP = true;
              LLMNR = "no";
              DHCP = "no";
              # XXX:
              # LL addresses are tempting for automatic ipv6 assignments,
              # but they're kind of unwieldy (eg, trying to ping somehost.local
              # will probably give you an ipv6 address, but you may need to specify
              # a scope id or netdev to ping that address :/)
              LinkLocalAddressing = "no";
            };
            routes = mkIf cfg.networks.${batdev}.routeToExits [
              {
                Source = "0.0.0.0";
                Destination = "0.0.0.0/0";
                Metric = cfg.networks.${batdev}.metric;
              }
            ];
            extraConfig =
              with cfg.networks.${batdev}.aqm;
              mkIf enable ''
                [CAKE]
                RTTSec = ${toString roundTripMillisec}ms
                Bandwidth = ${toString bandwidthMbps}M
                # BATMAN header adds 32 bytes/packet
                OverheadBytes = 32
                PriorityQueueingPreset = diffserv4
                FlowIsolationMode = dst-host
              '';
          };
        };

      allWifiDevices = mergeAttrsList (map (bat: cfg.networks.${bat}.devices) batmanDevices);
      allWifiDevNames = attrNames allWifiDevices;
    in
    {
      assertions = mkIf cfg.enable [
        {
          assertion = allUnique wifiDevices;
          message = "wifi devs in networks.<name>.devices must appear at most once across all networks";
        }
        {
          assertion = (intersectLists batmanDevices wifiDevices) == [ ];
          message = ''
            BATMAN mesh netdevs cannot be used in place of "plain" WiFi devices.
            Don't put a BATMAN device in networks.{...}.devices, and
            don't use a WiFi device name as networks.$name.
          '';
        }
        {
          assertion = (cfg.exitDevice != null) -> !(elem cfg.exitDevice wifiDevices);
          message = "Exit netdev ${cfg.exitDevice} can't also be enslaved to any BATMAN mesh netdev";
        }
        {
          assertion = (cfg.exitDevice != null) -> !(elem cfg.exitDevice batmanDevices);
          message = "A managed BATMAN device cannot be used as an exit device";
        }
      ];
      networking.nat = mkIf (cfg.exitDevice != null) {
        enable = true;
        externalInterface = cfg.exitDevice;
        internalInterfaces = batmanDevices;
      };
      networking.nftables = mkIf (cfg.exitDevice != null) { enable = true; };
      networking.firewall.extraForwardRules = mkIf (cfg.exitDevice != null) (
        let
          forwardFrom = batdev: "iifname ${batdev} oifname ${cfg.exitDevice} accept";
        in
        concatStringsSep "\n" (map forwardFrom batmanDevices)
      );

      # Ensure that NetworkManager doesn't try to reconfigure any WiFi devs participating in
      # any of our mesh nets
      networking.networkmanager.unmanaged =
        let
          wifiDevices = concatMap (net: attrNames net.devices) (attrValues cfg.networks);
        in
        map (x: "interface-name:${x}") wifiDevices;

      # Use systemd-networkd to manage address assignment, define batman devs
      systemd.network = {
        enable = true;
        wait-online.enable = false;
        netdevs = genAttrs batmanDevices (batmanDev: {
          netdevConfig = {
            Name = batmanDev;
            Kind = "batadv";
          };
          batmanAdvancedConfig = {
            GatewayMode =
              if cfg.exitDevice != null then
                "server"
              else if cfg.networks.${batmanDev}.routeToExits then
                "client"
              else
                "off";
            RoutingAlgorithm = "batman-v";
            OriginatorIntervalSec = "5";
          };
          # these settings not present in the nixos module; have to bring along the snippet
          # ourselves
          extraConfig =
            let
              configureBandwidth =
                inAttr: outAttr:
                optionalString (
                  (cfg.${inAttr} != null) && (cfg.exitDevice != null)
                ) "${outAttr} = ${toString cfg.${inAttr}}M";
            in
            ''
              [BatmanAdvanced]
              ${configureBandwidth "uploadMbps" "GatewayBandwidthUp"}
              ${configureBandwidth "downloadMbps" "GatewayBandwidthDown"}
            '';
        });
        networks = mergeAttrsList (map defineNetworksFor batmanDevices);
        links = mergeAttrsList (map defineLinksFor batmanDevices);
      };

      # Configure all WiFi devs with wpa_supplicant
      networking.supplicant = genAttrs allWifiDevNames (name: {
        userControlled.enable = true;
        configFile.path = "${
          config.networking.supplicant.${name}.userControlled.socketDir
        }/wpa_supplicant.${name}.conf";
        extraConf = ''
          country=${cfg.country}
          p2p_disabled=1
          # Force hash-to-element for SAE password element derivation;
          # there are widely-known sidechannel attacks on the older hunt-and-peck method
          sae_pwe=1
          pmf=1 # protected mgmt frames
          mesh_max_inactivity=10 # BATMAN ELP traffic should make 10s acceptable
          user_mpm=1 # don't rely on driver mesh peering manager
        '';
      });

      # Create prestarts that prevent the password from needing to be stored in the Nix store.
      systemd.services = listToAttrs (
        map (
          name:
          let
            extraConf = pkgs.writeText "wpa_supplicant.${name}.conf" ''
              network={
                ieee80211w=2 # force protected management frames
                ssid="${allWifiDevices.${name}.essid}"
                sae_password="@@PASSWORD@@"
                key_mgmt=SAE
                # Forbid "transition mode" support (we don't need to support WPA2 clients)
                sae_pk=1
                mesh_fwding=0 # disables default 802.11s routing algo
                frequency=${toString allWifiDevices.${name}.channel}
                mode=5 # mesh-point
              }
            '';
          in
          {
            name = "supplicant-${name}";
            value = {
              preStart = mkAfter ''
                conf=${escapeShellArg config.networking.supplicant.${name}.configFile.path}
                password_file=${escapeShellArg allWifiDevices.${name}.passwordFile}
                if [ ! -f "$password_file" ]; then
                  echo "File '$password_file' didn't exist" >&2
                  exit 1
                fi
                password="$(<"$password_file")"
                if [ -z "$password" ]; then
                  echo "No mesh password found in '$password_file'!" >&2
                  exit 1
                fi
                truncate -s0 "$conf"
                cat ${extraConf} >> "$conf"
                ${pkgs.gnused}/bin/sed -i "$(printf 's\001@@PASSWORD@@\001%s\001g' "$password")" "$conf"
              '';
            };
          }
        ) allWifiDevNames
      );
    }
  );
}
