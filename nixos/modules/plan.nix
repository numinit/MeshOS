/**
  MeshOS - Copyright (C) 2024+ MeshOS Contributors
  SPDX-License-Identifier: LGPL-3.0-or-later
  Authors:
    Morgan Jones <me@numin.it>
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
  inherit (lib.trivial) mod;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.strings) substring match;
  inherit (lib.lists)
    length
    head
    flatten
    mutuallyExclusive
    unique
    singleton
    optional
    map
    foldl
    ;
  inherit (lib.attrsets)
    mapAttrs
    mapAttrsToList
    filterAttrs
    attrValues
    ;
  inherit (builtins) fromTOML hashString;
  inherit ((pkgs.callPackage ../../lib/net.nix { }).lib) net;

  plan = config.networking.mesh.plan;
  thisHost = plan.hosts.${config.networking.hostName};

  # Each host with names and host IDs added.
  hostsWithNames = mapAttrs (
    name: value:
    value
    // {
      inherit name;
    }
  ) plan.hosts;

  hostsWhere = predicate: filterAttrs (_: predicate) plan.hosts;

  readOnly =
    type: value:
    mkOption {
      inherit type;
      default = value;
      readOnly = true;
    };

  readOnlyFn = type: value: readOnly (types.functionTo type) value;

  hostType = types.submodule (
    { config, name, ... }:
    {
      options = {
        name = readOnly types.str name;
        id = {
          hex = readOnly types.str (substring 0 8 (hashString "sha256" name));
          dec = readOnly types.ints.u32 (fromTOML "x = 0x${config.id.hex}").x;
        };

        owner = mkOption {
          type = types.str;
          default = name;
          description = "The username of the account who owns this node. Defaults to the node name.";
        };

        wifi = {
          address = mkOption {
            default = null;
            type = with types; nullOr str;
            description = "Address of the 802.11s mesh interface.";
          };
        };

        nebula = {
          address = mkOption {
            default = null;
            type = with types; nullOr net.types.ipv4;
            description = "The IPv4 address on the Nebula network";
          };
          entryAddresses = mkOption {
            default = [ ];
            type = with types; listOf (either net.types.ipv4 net.types.ipv6);
            description = "Nebula entry addresses, in descending priority order";
          };
          port = mkOption {
            default = null;
            type = with types; nullOr port;
            description = "Set to the port for your Nebula router.";
          };
          isLighthouse = mkEnableOption "lighthouse";
          isRelay = mkEnableOption "relay";
          unsafeRoutes = mkOption {
            default = [ ];
            type =
              with types;
              listOf (submodule {
                options = {
                  route = mkOption {
                    type = net.types.cidrv4;
                    description = "The subnet we should route to. Must be signed into the cert!";
                  };
                  metric = mkOption {
                    type = with types; nullOr ints.u16;
                    description = "The metric for this route";
                    default = null;
                  };
                };
              });
            description = "Additional subnets this router should be responsible for serving";
          };
          installDefaultRoute = mkOption {
            default = false;
            type = types.bool;
            description = "True if we should create routes that route all traffic through Nebula.";
          };
          defaultRouteMetric = mkOption {
            default = null;
            type = with types; nullOr int;
            description = "The metric for the default route.";
          };
        };

        dns = {
          addresses = mkOption {
            type = with types; attrsOf (listOf str);
            default = { };
            description = "Map of IP addresses to lists of hostnames. Will be added to all nodes' hostfile.";
          };
        };

        ssh = {
          hostKey = mkOption {
            type = types.str;
            default = null;
            description = "The SSH host key, if known";
          };
          port = mkOption {
            type = types.port;
            default = 22;
            description = "The SSH port";
          };
        };

        cache = {
          server = {
            priority = mkOption {
              type = types.int;
              default = 10;
              description = "The cache server priority.";
            };
            port = mkOption {
              type = types.port;
              default = 8501;
              description = "The cache server port";
            };
            sets = mkOption {
              type = with types; listOf str;
              default = [ ];
              description = "The sets this cache should provide.";
            };
            pubkey = mkOption {
              type = with types; nullOr str;
              default = null;
              description = "The cache pubkey";
            };
          };
          client = {
            sets = mkOption {
              type = with types; listOf str;
              default = [ ];
              description = "The sets this Nix instance should trust and fetch from.";
            };
          };
        };

        /*
          build = {
            server = {
              system = mkOption {
                type = types.str;
                default = "x86_64-linux";
                description = "This builder's system";
              };
              sshUser = mkOption {
                type = types.str;
                default = "nixbld";
                description = "The user for SSH";
              };
              maxJobs = mkOption {
                type = types.int;
                default = 1;
                description = "The max jobs for this builder";
              };
              speedFactor = mkOption {
                type = types.int;
                default = 1;
                description = "The speed factor for this builder";
              };
              supportedFeatures = mkOption {
                type = with types; listOf str;
                default = [
                  "nixos-test"
                  "big-parallel"
                  "kvm"
                  "benchmark"
                ];
                description = "Features this builder supports";
              };
              sets = mkOption {
                type = with types; listOf str;
                default = [ ];
                description = "The sets this builder should provide.";
              };
            };
            client = {
              sets = mkOption {
                type = with types; listOf str;
                default = [ ];
                description = "The sets we should use for builds.";
              };
            };
          };
        */
      };
    }
  );

  readOnlyHosts = readOnly (types.attrsOf hostType);
  readOnlyHostsFn = readOnlyFn (types.attrsOf hostType);
in
{
  options = {
    networking.mesh.plan = {
      ntp = {
        servers = readOnlyHosts (hostsWhere (host: host ? ntp && (host.ntp.port or null) != null));
      };

      dns = {
        servers = readOnlyHosts (hostsWhere (host: host ? dns && (host.dns.port or null) != null));
        staticHosts = readOnly (with types; attrsOf (listOf str)) (
          foldl (acc: host: acc // (host.dns.addresses or { })) { } (attrValues hostsWithNames)
        );
      };

      nebula = {
        lighthouses = readOnlyHosts (hostsWhere (host: (host ? nebula) && host.nebula.isLighthouse));
        relays = readOnlyHosts (hostsWhere (host: (host ? nebula) && host.nebula.isRelay));

        # Entry addresses for Nebula.
        entryAddresses = readOnly (with types; listOf (either net.types.ipv4 net.types.ipv6)) (
          flatten (
            map (host: host.nebula.entryAddresses) (
              attrValues (hostsWhere (host: (host ? nebula) && (host.nebula.entryAddresses or [ ]) != [ ]))
            )
          )
        );

        # Default routers for Nebula.
        defaultRouters = readOnlyHosts (
          hostsWhere (host: (host ? nebula) && (host.nebula.defaultRoute or false) == true)
        );

        # Unsafe routes for Nebula. Attrsets with route, via, and (optionally) metric.
        unsafeRoutes = readOnly (with types; listOf attrs) (
          flatten (
            map (host: map (route: route // { via = host.nebula.address; }) host.nebula.unsafeRoutes) (
              attrValues (hostsWhere (host: (host ? nebula) && length (host.nebula.unsafeRoutes or [ ]) > 0))
            )
          )
        );

        # Routes for Nebula. Just all the unique unsafe routes plus the main subnet.
        routes = readOnly (types.listOf net.types.cidrv4) (
          unique (singleton plan.nebula.subnet ++ map (route: route.route) plan.nebula.unsafeRoutes)
        );

        # Gets a port for this host.
        portFor = readOnlyFn types.port (
          host:
          let
            basePort = 5000;
            modulo = 512;
          in
          if host.nebula.port == null then (basePort + (mod host.id.dec modulo)) else host.nebula.port
        );

        # The Nebula static host map, keyed by Nebula address.
        staticHosts = readOnly (with types; attrsOf (listOf str)) (
          foldl
            (
              acc: host:
              acc
              // {
                ${host.nebula.address} = map (x: "${x}:${toString (plan.nebula.portFor host)}") (
                  flatten (attrValues host.dns.addresses)
                );
              }
            )
            { }
            (
              attrValues (
                hostsWhere (
                  host:
                  (host ? nebula)
                  && (host.nebula.address or null) != null
                  && (length (attrValues (host.dns.addresses or { }))) > 0
                )
              )
            )
        );

        dnsServerAddresses = readOnly (types.listOf net.types.ipv4) (
          mapAttrsToList (_: host: host.nebula.address) (
            filterAttrs (_: host: host ? nebula) plan.nebula.dnsServers
          )
        );
      };

      nix = {
        caches = readOnlyHostsFn (
          sets:
          hostsWhere (
            host:
            ((host.cache.server.port or null) != null)
            && (sets == null || !(mutuallyExclusive (host.cache.server.sets or [ ]) sets))
          )
        );
        builders = readOnlyHostsFn (
          sets:
          hostsWhere (
            host:
            ((host.build.hostName or null) != null)
            && ((host.ssh.hostKey or null) != null)
            && ((host.ssh.port or null) == 22)
            && (sets == null || !(mutuallyExclusive (host.build.sets or [ ]) sets))
          )
        );

        # URLs of all binary caches
        cacheURLs = readOnlyFn (with types; listOf str) (
          sets:
          flatten (
            mapAttrsToList (
              _: host:
              let
                mkUrl =
                  addressOrCidr:
                  let
                    addressMatch = match "^([^/]+)(/[0-9]+)?$" addressOrCidr;
                  in
                  assert addressMatch != null;
                  "http://${head addressMatch}:${toString host.cache.server.port}?priority=${toString host.cache.server.priority}";
              in
              optional (host.wifi.address or null != null) (mkUrl host.wifi.address)
              ++ optional (host.nebula.address or null != null) (mkUrl host.nebula.address)
            ) (plan.nix.caches sets)
          )
        );

        # All package signing pubkeys
        cachePubkeys = readOnlyFn (with types; listOf str) (
          sets:
          mapAttrsToList (_: host: host.cache.server.pubkey) (
            filterAttrs (_: host: (host.cache.server.pubkey or null) != null) (plan.nix.caches sets)
          )
        );
      };

      hosts = mkOption {
        type = types.attrsOf hostType;
        default = { };
      };

      constants = {
        wifi = {
          primaryChannel = mkOption {
            type = types.int;
            description = ''
              Frequency, in MHz, on which the wireless device should operate.
              To determine which your hardware supports, run `iw phy`.

              It's recommended to avoid frequencies that `iw phy` marks "no IR"
              because it will prevent creating a mesh-point when no established ones are
              reachable.
            '';
          };
          secondaryChannel = mkOption {
            type = types.int;
            description = ''
              Secondary frequency, in MHz, on which the wireless device should operate.
              To determine which your hardware supports, run `iw phy`.

              It's recommended to avoid frequencies that `iw phy` marks "no IR"
              because it will prevent creating a mesh-point when no established ones are
              reachable.
            '';
          };
          essid = mkOption {
            type = types.str;
            description = ''
              The mesh ID to join or create. This is basically an ESSID.
            '';
          };
          passwordFile = mkOption {
            type = types.path;
            description = ''
              The file containing the password to use for the mesh network.
            '';
          };
        };
        nebula = {
          subnet = mkOption {
            type = net.types.cidrv4;
            description = "The Nebula subnet";
          };
          caBundle = mkOption {
            type = types.path;
            description = "The path to the Nebula CA bundle.";
          };
        };
      };
    };
  };
}
