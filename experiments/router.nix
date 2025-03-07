{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}:

let
  inherit (lib.attrsets) mapAttrsToList;
  inherit (lib.options) types;
  inherit ((pkgs.callPackage ../lib/net.nix { }).lib) net;

  cfg = config.networking.mesh.plan.${config.networking.hostName};

  # Interfaces that can manage the router.
  trustedIfs = lib.singleton "lo" ++ lib.optional cfg.router.management.enable "management";

  # Layer 2 mesh.
  meshIfs = lib.optional cfg.router.mesh.enable "mesh";

  # VPN.
  vpnIfs = lib.optional cfg.nebula.enable cfg.nebula.networkName;

  # LANs.
  lanIfs =
    lib.optional cfg.interfaces.management.enable "management"
    ++ lib.optional cfg.interfaces.lan.enable "lan"
    ++ lib.optional cfg.interfaces.guest.enable "guest";
  hasLanIfs = builtins.length lanIfs > 0;
  selfAndLanIfs = lib.singleton "lo" ++ lanIfs;

  # Interfaces in the LAN security zone, including the VPN.
  mostlyTrustedIfs = lib.optional cfg.interfaces.lan.enable "lan" ++ vpnIfs;

  # Interfaces in the WLAN security zone.
  lessTrustedIfs = lib.optional cfg.interfaces.guest.enable "guest" ++ meshIfs;

  # Interfaces that we're exiting through. These are untrusted.
  untrustedIfs =
    lib.optional cfg.interfaces.wan.enable "wan"
    ++ lib.optional cfg.interfaces.wwan.enable "wwan"
    ++ lib.optional cfg.interfaces.modem.enable "modem";

  # Interfaces that one can route through.
  routableIfs = meshIfs ++ vpnIfs ++ untrustedIfs;
in
{
  options = {
    networking.mesh.router = {
      dns = {
        tsigSecretFile = lib.mkOption {
          type = types.path;
          description = "the file containing the TSIG secret";
          default = "/etc/tsig.secret";
        };
      };
    };
  };

  config = lib.mkMerge [
    {
      networking =
        let
          isWanDhcp = cfg.interfaces.wan.enable && cfg.interfaces.wan.dhcp.enable;
          isWwanDhcp = cfg.interfaces.wwan.enable && cfg.interfaces.wwan.dhcp.enable;
          isModemDhcp = cfg.interfaces.modem.enable && cfg.interfaces.modem.dhcp.enable;
        in
        {
          nameservers = lib.mkIf cfg.dns.enable (lib.mkDefault [ "127.0.0.1" ]);

          nat.enable = lib.mkDefault false;
          firewall.enable = lib.mkDefault false;

          dhcpcd = {
            allowInterfaces =
              lib.optional isWanDhcp "wan" ++ lib.optional isWwanDhcp "wwan" ++ lib.optional isModemDhcp "modem";

            extraConfig =
              lib.optionalString isWanDhcp ''
                interface wan
                metric ${toString cfg.interfaces.wan.metric}
              ''
              + lib.optionalString isWwanDhcp ''
                interface wwan
                metric ${toString cfg.interfaces.wwan.metric}
              ''
              + lib.optionalString isModemDhcp ''
                interface modem
                metric ${toString cfg.interfaces.modem.metric}
              '';
          };

          interfaces = {
            wan = lib.mkIf cfg.interfaces.wan.enable { useDHCP = isWanDhcp; };
            wwan = lib.mkIf cfg.interfaces.wwan.enable { useDHCP = isWwanDhcp; };
            modem = lib.mkIf cfg.interfaces.modem.enable { useDHCP = isModemDhcp; };
            management = lib.mkIf cfg.interfaces.management.enable {
              ipv4.addresses = [ { inherit (cfg.interfaces.management.v4) address prefixLength; } ];
            };
            lan = lib.mkIf cfg.interfaces.lan.enable {
              ipv4.addresses = [ { inherit (cfg.interfaces.lan.v4) address prefixLength; } ];
            };
            guest = lib.mkIf cfg.interfaces.guest.enable {
              ipv4.addresses = [ { inherit (cfg.interfaces.guest.v4) address prefixLength; } ];
            };
          };

          bridges = {
            wan = lib.mkIf cfg.interfaces.wan.enable { inherit (cfg.interfaces.wan) interfaces; };
            wwan = lib.mkIf cfg.interfaces.wan.enable { inherit (cfg.interfaces.wwan) interfaces; };
            modem = lib.mkIf cfg.interfaces.modem.enable { inherit (cfg.interfaces.modem) interfaces; };
            management = lib.mkIf cfg.interfaces.management.enable {
              inherit (cfg.interfaces.management) interfaces;
            };
            lan = lib.mkIf cfg.interfaces.lan.enable { inherit (cfg.interfaces.lan) interfaces; };
            guest = lib.mkIf cfg.interfaces.guest.enable { inherit (cfg.interfaces.guest) interfaces; };
          };

          # TODO: use notnft or nixos-router. This is miserable but fixing it was out of scope.
          # Our focus was the mesh stuff. Do this more nicely in the future. :-)
          nftables =
            let
              # Converts a list of interfaces into a nftables list.
              ifList = ifs: "{${lib.concatMapStringsSep (x: ''"${x}"'') ifs}}";
            in
            {
              enable = true;
              tables = {
                filter = {
                  family = "inet";
                  content =
                    ''
                      chain output {
                        type filter hook output priority 100; policy accept;
                      }

                      chain input {
                        type filter hook input priority filter; policy drop;

                        # Allow trusted networks to access the router
                        iifname ${ifList (trustedIfs ++ mostlyTrustedIfs ++ lessTrustedIfs)} counter accept;

                        # Allow returning traffic from routable interfaces
                        iifname ${ifList routableIfs} ct state {established, related} counter accept;

                        # Allow some ICMP by default
                        ip protocol icmp icmp type {destination-unreachable, echo-request, time-exceeded, parameter-problem} accept;
                        ip6 nexthdr icmpv6 icmpv6 type {destination-unreachable, echo-request, time-exceeded, parameter-problem, packet-too-big} accept;
                    ''
                    + lib.optionalString config.networking.mesh.nebula.enable ''
                      # Allow Nebula traffic for VPN entry.
                      udp dport ${toString config.networking.mesh.nebula.port} counter accept;
                    ''
                    + ''
                        # Drop everything else from untrusted external interfaces
                        iifname ${ifList untrustedIfs} drop;
                      }

                      chain forward {
                        type filter hook forward priority filter; policy drop;

                        # Allow trusted networks access to arena or the mesh
                        iifname ${
                          ifList (trustedIfs ++ mostlyTrustedIfs)
                        } ofiname ${ifList (meshIfs ++ vpnIfs)} counter accept comment "Allow trusted LAN to Arena or the mesh";

                        # Allow less trusted networks access to the mesh
                        iifname ${ifList lessTrustedIfs} oifname ${ifList meshIfs} counter accept comment "Allow less trusted LAN to the mesh";
                    ''
                    + lib.optionalString config.networking.mesh.nebula.enable ''
                      # Allow less trusted networks to get internet access without being able to hit LAN
                      iifname ${ifList (lessTrustedIfs ++ meshIfs)} oifname ${vpnIfs} ip daddr {
                        ${lib.concatStringsSep ", " (
                          mapAttrsToList (_: host: host.nebula.address) config.networking.mesh.plan.nebula.defaultRouters
                        )}
                      } counter accept comment "Allow less trusted LAN to hit default routers";
                      iifname ${ifList (lessTrustedIfs ++ meshIfs)} oifname ${vpnIfs} ip daddr != {
                        10.0.0.0/8,
                        172.16.0.0/12,
                        192.168.0.0/16,
                        127.0.0.0/8
                      } counter accept comment "Allow less trusted LAN to get internet access";
                    ''
                    + ''
                        # Allow localhost access to untrusted public networks
                        iifname ${ifList [ "lo" ]} oifname ${ifList untrustedIfs} counter accept comment "Allow localhost to untrusted networks";

                        # Allow established WAN to return
                        iifname ${ifList routableIfs} oifname ${ifList selfAndLanIfs} ct state established,related counter accept comment "Allow established back to LANs";
                      }
                    '';
                };

                nat = {
                  family = "ip";
                  content =
                    ''
                      chain prerouting {
                        type nat hook prerouting priority filter;
                    ''
                    + lib.optionalString cfg.dns.enable ''
                      # Redirect DNS and NTP queries from LANs to us
                      iifname ${ifList lanIfs} udp dport {${toString cfg.dns.port}} counter redirect
                    ''
                    + lib.optionalString cfg.ntp.enable ''
                      iifname ${ifList lanIfs} udp dport {${toString cfg.ntp.port}} counter redirect
                    ''
                    + ''
                      }

                      # Setup NAT masquerading on the VPN and mesh interfaces
                      chain postrouting {
                        type nat hook postrouting priority filter; policy accept;
                        oifname ${ifList (meshIfs ++ vpnIfs)} masquerade;
                      }
                    '';
                };
              };
            };
        };

      systemd = {
        network.wait-online.enable = false;

        services = lib.mkIf cfg.transports.wwan.enable (
          builtins.listToAttrs (map (
            interface:
            # HACK to support pluggable devices: https://github.com/NixOS/nixpkgs/pull/155017
            lib.nameValuePair "wpa_supplicant-${interface}" {
              serviceConfig = {
                Restart = "always";
                RestartSec = 15;
              };
            }
          )) cfg.transports.wwan.interfaces
        );
      };

      services = {
        # Restart the supplicant and network-addresses if we get a hotplug.
        udev.extraRules = lib.mkIf cfg.transports.wwan.enable (
          builtins.concatStringsSep "\n" (
            map (interface: ''
              SUBSYSTEM=="net", KERNEL=="${interface}", TAG+="systemd", \
                ENV{SYSTEMD_WANTS}+="wpa_supplicant-${interface}.service", ENV{SYSTEMD_WANTS}+="network-addresses-${interface}.service"
            '') cfg.transports.wwan.interfaces
          )
        );
      };

      ntp = {
        enable = true;
        servers = lib.flatten (
          mapAttrsToList (_: host: builtins.attrValues host.dns.addresses) (
            lib.filterAttrs (name: value: value ? dns) config.networking.mesh.plan.ntp.servers
          )
        );
      };

      kea.dhcp4 = {
        enable = lib.mkDefault hasLanIfs;
        settings = {
          valid-lifetime = lib.mkDefault 3600;
          renew-timer = lib.mkDefault 900;
          rebind-timer = lib.mkDefault 1800;

          option-def = [
            {
              name = "rfc3442-classless-static-routes";
              code = 121;
              space = "dhcp4";
              type = "record";
              array = true;
              record-types = "uint8,uint8,uint8,uint8,ipv4-address";
            }
          ];

          lease-database = {
            type = "memfile";
            persist = true;
            name = "/var/lib/kea/dhcp4.leases";
          };

          interfaces-config = {
            dhcp-socket-type = "raw";
            interfaces = lanIfs;

            # Retry the socket binding until we're bound. Give up after an hour.
            service-sockets-retry-wait-time = lib.mkDefault 5000;
            service-sockets-max-retries = lib.mkDefault (
              (3600 * 1000) / config.services.kea.dhcp4.settings.interfaces-config.service-sockets-retry-wait-time
            );
          };

          subnet4 = map (
            ifName:
            let
              transport = cfg.transports.${ifName};
            in
            rec {
              subnet = transport.v4.network;
              pools = [
                {
                  pool =
                    net.cidr.host (transport.v4.dhcp.start) transport.v4.network
                    + " - "
                    + net.cidr.host (transport.v4.dhcp.start + transport.v4.dhcp.limit) transport.v4.network;
                }
              ];
              ddns-qualifying-suffix = "${ifName}.${cfg.dns.domain}";
              option-data = [
                {
                  name = "routers";
                  data = transport.v4.address;
                  always-send = true;
                }
                {
                  name = "domain-name-servers";
                  data = transport.v4.address;
                  always-send = true;
                }
                {
                  name = "domain-name";
                  data = ddns-qualifying-suffix;
                  always-send = true;
                }
              ];
            }
          ) lanIfs;

          # Enable communication between dhcp4 and a local dhcp-ddns
          # instance.
          # https://kea.readthedocs.io/en/kea-2.2.0/arm/dhcp4-srv.html#ddns-for-dhcpv4
          dhcp-ddns = {
            enable-updates = true;
          };

          ddns-send-updates = true;
          ddns-qualifying-suffix = cfg.dns.domain;
          ddns-update-on-renew = true;
          ddns-replace-client-name = "when-not-present";
          hostname-char-set = "[^A-Za-z0-9-]";
          hostname-char-replacement = "";
        };
      };

      kea.dhcp-ddns = {
        enable = lib.mkDefault hasLanIfs;
        settings = {
          forward-ddns = {
            ddns-domains = [
              {
                name = "${cfg.dns.domain}.";
                key-name = cfg.dns.domain;
                dns-servers = [
                  {
                    ip-address = "127.0.0.1";
                    port = 5354;
                  }
                ];
              }
            ];
          };
          tsig-keys = [
            {
              name = cfg.dns.domain;
              algorithm = "HMAC-SHA256";
              secret = "@@TSIG_SECRET@@";
            }
          ];
        };
      };

      knot =
        let
          zone = pkgs.writeTextDir "${cfg.dns.domain}.zone" ''
            @ SOA ns.${cfg.dns.domain} nox.${cfg.dns.domain} 0 86400 7200 3600000 172800
            @ NS nameserver
            nameserver A 127.0.0.1
          '';
          zonesDir = pkgs.buildEnv {
            name = "knot-zones";
            paths = [ zone ];
          };
        in
        {
          enable = lib.mkDefault cfg.dns.enable;
          extraArgs = [ "-v" ];
          settings = {
            server = {
              listen = "127.0.0.1@5354";
            };
            log = {
              syslog = {
                any = "debug";
              };
            };
            key = {
              ${cfg.dns.domain} = {
                algorithm = "hmac-sha256";
                secret = "@@TSIG_SECRET@@";
              };
            };
            acl = {
              "key.${cfg.dns.domain}" = {
                key = cfg.dns.domain;
                action = "update";
              };
            };
            template = {
              default = {
                storage = zonesDir;
                zonefile-sync = -1;
                zonefile-load = "difference-no-serial";
                journal-content = "all";
              };
            };
            zone = {
              ${cfg.dns.domain} = {
                file = "${cfg.dns.domain}.zone";
                acl = [ "key.${cfg.dns.domain}" ];
              };
            };
          };
        };

      # TODO: use notlua.
      kresd =
        let
          # Convert extra hosts we've DNS blackholed into a RPZ list.
          extraHosts = pkgs.stdenv.mkDerivation {
            name = "extra-hosts.rpz";
            src = pkgs.writeText "extra-hosts" config.networking.extraHosts;
            phases = [ "installPhase" ];
            installPhase = ''
              echo -e '$TTL'"\t2\n@\tIN\tSOA\tlocalhost.\troot.localhost.\t(\n\t\t2\t;\tserial\n\t\t2w\t;\trefresh\n\t\t2w\t;\tretry\n\t\t2w\t;\texpiry\n\t\t2w)\t;\tminimum\n\t\tIN\tNS\tlocalhost.\n\n" > $out
              (cat $src | \
                grep -E '[0-9a-f:]+|(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])|(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])' | \
                ${pkgs.gawk}/bin/awk '{sub(/\r$/,"")} {sub(/^127\.0\.0\.1/,"0.0.0.0")} BEGIN { OFS = "" } NF == 2 && $1 == "0.0.0.0" { print $2 }' | \
                sort -u | \
                ${pkgs.gawk}/bin/awk 'BEGIN { OFS = "" } NF == 1 { print $1,"\tCNAME\t."; print "*.",$1,"\tCNAME\t."}' >> $out) || true
            '';
          };
          toTable = values: "${lib.concatStringsSep ", " (map (x: "'${x}'") values)}";
        in
        {
          # knot resolver daemon
          enable = true;
          package = pkgs.knot-resolver.override { extraFeatures = true; };

          listenPlain = [
            "127.0.0.1:53"
            "[::1]:53"
          ] ++ (map (ifName: "${cfg.transports.${ifName}.v4.address}:53") lanIfs);

          extraConfig =
            ''
              cache.size = 128 * MB

              modules = {
                'policy',
                'view',
                'hints',
                'serve_stale < cache',
                'workarounds < iterate',
                'stats',
                'predict'
              }

              -- Prefetch learning (20-minute blocks over 24 hours)
              predict.config({ window = 20, period = 72 })

              -- Accept all requests from these subnets
              subnets = {${toTable [ "127.0.0.0/8" ]}}
              local_domains = {}
              upstreams = {}
            ''
            + lib.optionalString hasLanIfs ''
              subnets = {${
                toTable (map (ifName: cfg.transports.${ifName}.v4.network) lanIfs)
              }, table.unpack(subnets)}
              local_domains = {${
                toTable (map (ifName: "${ifName}.${cfg.dns.domain}") lanIfs)
              }, table.unpack(local_domains)}
            ''
            + ''
              for i, v in ipairs(subnets) do
                view:addr(v, function(req, qry) return policy.PASS end)
              end

              -- Drop everything that hasn't matched
              view:addr('0.0.0.0/0', function(req, qry) return policy.DROP end)

              -- Blackhole the hosts in our RPZ list.
              policy:add(policy.rpz(policy.DENY, '${extraHosts}', false))

              -- Forward requests for the local DHCP domains.
              for i, v in ipairs(local_domains) do
                policy:add(policy.suffix(policy.FORWARD({'127.0.0.1@5354'}), {todname(v)}))
              end

              -- Stub to our upstream DNS servers
              stub_upstreams = {}
            ''
            +
              lib.optionalString
                (
                  config.networking.mesh.nebula.enable && builtins.length config.networking.mesh.plan.dns.servers > 0
                )
                ''
                  -- Pick Nebula hosts that have a DNS server, since we know stubbing over Nebula is secure.
                  stub_upstreams = {${
                    toTable (
                      builtins.filter (x: x != null) (
                        mapAttrsToList (
                          _: host:
                          if (host.nebula.ip or null != null) then "${host.nebula.ip}@${toString host.dns.port}" else null
                        ) config.networking.mesh.plan.dns.servers
                      )
                    )
                  }, table.unpack(stub_upstreams)}
                ''
            + ''
              if #stub_upstreams > 0 then
                policy:add(policy.all(policy.STUB(stub_upstreams)))
              end
            '';
        };
    }
  ];
}
