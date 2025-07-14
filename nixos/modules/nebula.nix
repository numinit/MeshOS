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
  inherit (lib.strings) escapeShellArg;
  inherit (lib.modules)
    mkIf
    mkMerge
    mkAfter
    mkForce
    mkDefault
    ;
  inherit (lib.options) mkOption mkEnableOption;
  inherit (lib.lists)
    optional
    optionals
    remove
    singleton
    sublist
    flatten
    filter
    ;
  inherit (lib.attrsets) mapAttrsToList filterAttrs optionalAttrs;
  inherit (lib.path) subpath append splitRoot;
  inherit (pkgs.callPackage ../lib/disjointCidr.nix { }) generateDisjointCidrs;

  cfg = config.networking.mesh.nebula;
  plan = config.networking.mesh.plan;
  hostCfg = plan.hosts.${config.networking.hostName};
in
{
  options = {
    networking.mesh.nebula = {
      enable = mkEnableOption "nebula VPN";
      networkName = mkOption {
        description = "The name of the network.";
        default = "mesh3";
        type = types.str;
      };
      tpm2Key = mkOption {
        description = "Set to true or a nixpkcs spec for a TPM2 key.";
        default = false;
        type = with types; either attrs bool;
      };
      privateKey = mkOption {
        description = "String with path or PKCS#11 URI to your nebula private key.";
        default = "/etc/nebula/${cfg.networkName}/${config.networking.hostName}.key";
        type = types.str;
      };
      clientCertPath = mkOption {
        description = "Path to your nebula client certificate.";
        default = "/etc/nebula/${cfg.networkName}/${config.networking.hostName}.crt";
        type = types.path;
      };
      localSSHPort = mkOption {
        type = with types; nullOr port;
        default = null;
        description = "Set to the port for local SSH access to Nebula status.";
      };
      localDNSPort = mkOption {
        default = null;
        type = with types; nullOr port;
        description = "Set to the port for local DNS queries to Nebula";
      };
      dontRouteRfc1918 = mkOption {
        default = true;
        type = types.bool;
        description = "True if we shouldn't route RFC1918 traffic through Nebula. This is the default.";
      };
    };
  };
  config = mkMerge [
    # Basic Nebula network settings.
    (mkIf cfg.enable (
      let
        nebulaAddressesOf = mapAttrsToList (_: host: host.nebula.address);
        lighthouseHosts = plan.nebula.lighthouses;
        relayHosts = plan.nebula.relays;

        # TODO: let's merge #353665 and then get rid of this.
        extraCapabilities =
          let
            inherit (config.services.nebula) networks;
          in
          optional (networks.${cfg.networkName}.listen.port < 1024) "CAP_NET_BIND_SERVICE";
      in
      {
        # XXX: Move somewhere else.
        networking.hosts = plan.dns.staticHosts;

        # Add necessary capabilities. TODO: let's merge #353665 and then get rid of this.
        systemd.services."nebula@${cfg.networkName}".serviceConfig = {
          CapabilityBoundingSet = mkAfter extraCapabilities;
          AmbientCapabilities = mkAfter extraCapabilities;
        };

        # Configure the Nebula network.
        services.nebula.networks.${cfg.networkName} = {
          ca = plan.constants.nebula.caBundle;
          cert = cfg.clientCertPath;
          key = cfg.privateKey;
          tun.device = cfg.networkName;

          # Default to all interfaces.
          listen =
            let
              host = if (hostCfg.nebula.host or null) != null then hostCfg.nebula.host else "[::]";
            in
            {
              port = plan.nebula.portFor hostCfg;
              inherit host;
            };

          # Set the lighthouse and relay options.
          inherit (hostCfg.nebula) isLighthouse isRelay;
          lighthouses = remove hostCfg.nebula.address (nebulaAddressesOf lighthouseHosts);
          relays = remove hostCfg.nebula.address (nebulaAddressesOf relayHosts);

          # Static hosts.
          staticHostMap = filterAttrs (name: value: name != hostCfg.nebula.address) plan.nebula.staticHosts;

          # Defaults for the firewall.
          firewall = mkDefault rec {
            inbound = [
              {
                port = "any";
                proto = "any";
                host = "any";
              }
            ];
            outbound = inbound;
          };

          settings = {
            # Static host map. Use both IPv4 and v6 by default.
            static_map = {
              network = mkDefault "ip";
              lookup_timeout = mkDefault "5s";
            };

            # Turn on NAT hole punching.
            punchy.punch = mkDefault true;
            punchy.respond = mkDefault true;

            tun.unsafe_routes =
              # Default routes.
              optionals hostCfg.nebula.installDefaultRoute (
                flatten (
                  mapAttrsToList (
                    name: host:
                    map
                      (
                        route:
                        {
                          inherit route;
                          via = host.nebula.address;
                          install = true;
                        }
                        // optionalAttrs (builtins.isInt cfg.defaultRouteMetric) { metric = cfg.defaultRouteMetric; }
                      )
                      (
                        generateDisjointCidrs (
                          # RFC1918 shouldn't go through Nebula.
                          optionals cfg.dontRouteRfc1918 [
                            "10.0.0.0/8"
                            "172.16.0.0/12"
                            "192.168.0.0/16"
                            "169.254.0.0/16"
                          ]
                          # Traffic to the entry addresses shouldn't go through Nebula.
                          ++ (map (x: "${x}/32") plan.nebula.entryAddresses)

                          # And neither should loopback.
                          ++ singleton "127.0.0.0/8"
                        )
                      )
                  ) plan.nebula.defaultRouters
                )
              )
              # Unsafe routes that are explicitly declared.
              ++ map (attrs: attrs // { install = true; }) (
                filter (route: route.via != hostCfg.nebula.address) plan.nebula.unsafeRoutes
              );
          };
        };
      }
    ))

    # Configure local DNS.
    (mkIf (cfg.enable && cfg.localDNSPort != null) {
      services.nebula.networks.${cfg.networkName}.settings.lighthouse.dns = {
        host = "localhost";
        port = cfg.localDNSPort;
      };
    })

    # Configure local SSH.
    (mkIf (cfg.enable && cfg.localSSHPort != null) (
      let
        splitPath = splitRoot (/. + cfg.clientCertPath);
        splitSubpath = subpath.components splitPath.subpath;
        newSubpath =
          sublist 0 (builtins.length splitSubpath - 1) splitSubpath
          ++ singleton "ssh_host_ed25519_key";
        hostKeyPath = builtins.toString (append splitPath.root (subpath.join newSubpath));
      in
      {
        services.nebula.networks.${cfg.networkName}.settings.sshd = {
          enabled = true;
          listen = "localhost:${builtins.toString cfg.localSSHPort}";
          host_key = hostKeyPath;
          authorized_users = singleton {
            user = hostCfg.owner;
            keys = config.users.users.${hostCfg.owner}.openssh.authorizedKeys.keys or [ ];
          };
        };

        # TODO: upstream to Nebula module.
        systemd.services."nebula@${cfg.networkName}".serviceConfig.ExecStartPre =
          "+${pkgs.writeShellScript "nebula-${cfg.networkName}-pre-start" ''
            host_key=${escapeShellArg hostKeyPath}
            if [ ! -f "$host_key" ]; then
              dir="$(dirname -- "$host_key")"
              owner=nebula-${escapeShellArg cfg.networkName}:nebula-${escapeShellArg cfg.networkName}
              mkdir -p "$dir"
              ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f "$host_key" -N "" < /dev/null
              ${pkgs.coreutils}/bin/chmod 0600 "$host_key"
              ${pkgs.coreutils}/bin/chown "$owner" "$dir" "$host_key" "$host_key.pub"
            fi
          ''}";
      }
    ))

    (mkIf (cfg.enable && cfg.tpm2Key != false) {
      # So we pass down PKCS#11 environment variables to Nebula.
      systemd.services."nebula@${cfg.networkName}" = {
        environment = config.nixpkcs.keypairs.${cfg.networkName}.extraEnv;
      };

      # So Nebula can access the TPM key.
      users.users."nebula-${cfg.networkName}".extraGroups = mkAfter (singleton "tss");
    })

    # Try to use a key in a TPM if we're asked to.
    (mkIf (cfg.tpm2Key != false) (mkMerge [
      {
        nixpkcs = {
          enable = true;
          tpm2.enable = true;
          keypairs.${cfg.networkName} = mkMerge [
            {
              enable = true;
              inherit (pkgs.tpm2-pkcs11.abrmd) pkcs11Module;
              id = mkDefault 1;
              keyOptions = {
                algorithm = "EC";
                type = "secp256r1";
                usage = mkDefault [
                  "sign"
                  "derive"
                  "encrypt"
                  "wrap"
                ];
                soPinFile = mkDefault "/etc/nixpkcs/tpm2.user.pin";
                loginAsUser = mkDefault true;
              };
              certOptions = {
                subject = mkDefault "CN=${config.networking.hostName}";
                extensions = mkDefault [
                  "basicConstraints=critical,CA:FALSE"
                  "keyUsage=critical,digitalSignature,keyEncipherment"
                  "extendedKeyUsage=clientAuth"
                ];
                pinFile = mkDefault "/etc/nixpkcs/tpm2.user.pin";
                rekeyHook = pkgs.writeShellScript "nebula-rekey-hook" ''
                  set -euo pipefail

                  if [[ -v NIXPKCS_STORE_DIR ]] && [ -d "$NIXPKCS_STORE_DIR" ]; then
                    # Fix permissions on the store directory so tss can read it.
                    chown -R root:tss "$NIXPKCS_STORE_DIR";
                    chmod 0775 "$NIXPKCS_STORE_DIR"
                    find "$NIXPKCS_STORE_DIR" -type f -exec chmod 0664 {} \;
                  fi

                  if [ $# -gt 1 ] && [ "$2" == 'new' ]; then
                    # Write out the Nebula pubkey.
                    key="$1"
                    nebula_cert=${pkgs.nebula}/bin/nebula-cert
                    crt=${escapeShellArg cfg.clientCertPath}
                    dir="$(dirname -- "$crt")"
                    base="$(basename -- "$crt" .crt)"
                    x509="$dir/$base.x509.crt"
                    pub="$dir/$base.pub"
                    uri="$(echo "$NIXPKCS_KEY_SPEC" | jq -r '.uri')"

                    set -x
                    mkdir -p "$dir"
                    cat > "$x509"
                    rm -f "$pub"
                    "$nebula_cert" keygen \
                      -curve P256 \
                      -out-pub "$pub" \
                      -pkcs11 "$uri"
                    chown -R nebula-${escapeShellArg cfg.networkName}:nebula-${escapeShellArg cfg.networkName} "$dir" || true
                    set +x

                    echo "Your Nebula public key for '$key' is at: $pub" >&2
                    echo "Sign a cert, and place it at: $crt" >&2
                  fi
                '';
              };
            }

            # User specified TPM key options.
            (if cfg.tpm2Key == true then { } else cfg.tpm2Key)
          ];
        };
        networking.mesh.nebula.privateKey = mkForce config.nixpkcs.keypairs.${cfg.networkName}.uri;
      }
    ]))
  ];
}
