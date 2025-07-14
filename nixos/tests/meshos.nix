{
  lib,
  testers,
  self,
  pkgs,
  extraMachineOptions ? { },
}:

let
  hostAddress = id: "192.168.1.${toString (id + 1)}";
  serverAddress = hostAddress 1;

  meshPlan = {
    hosts = {
      # Should be in the mesh plan, not a participant.
      airgap = { };

      alice = {
        dns.addresses = {
          # Fixed mesh point node.
          "10.69.0.1" = [ "alice.airgap.local" ];
        };
        wifi.address = "10.69.0.1/16";
        nebula = {
          # Well-known lighthouse address.
          address = "10.32.32.32";
          entryAddresses = [ "10.69.0.1" ];
          isLighthouse = true;
          isRelay = true;
        };
        cache = {
          server = {
            sets = [ "alice" ];
            pubkey = "alice:BbsP2JaJUsPXf2FxGNzi488AXHLz+wVYAShHru+zUTA=";
          };
        };
      };
      bob = {
        wifi.address = "10.69.0.2/16";
        nebula = {
          address = "10.32.10.2";
          entryAddresses = [ "10.69.0.2" ];
        };
        cache = {
          client.sets = [ "alice" ];
          server = {
            sets = [ "bob" ];
            pubkey = "bob:prp0EOXKzU7/jvi9+ehee0JVEUlg6yyzV5UttZ+FvW4=";
          };
        };
      };
      charlie = {
        wifi.address = "10.69.0.3/16";
        nebula = {
          address = "10.32.10.3";
          entryAddresses = [ "10.69.0.3" ];
        };
        cache = {
          client.sets = [ "bob" ];
          server = {
            sets = [ "charlie" ];
            pubkey = "charlie:PedLH0jd4iUDN+6Amrm4NHmJyvoi3mXWPGW4g5IW7hA=";
          };
        };
      };
      dan = {
        wifi.address = "10.69.0.4/16";
        nebula = {
          # Make sure that port overrides work.
          port = 12345;
          address = "10.32.10.4";
          entryAddresses = [ "10.69.0.4" ];
        };
        cache = {
          client.sets = [ "charlie" ];
          server = {
            sets = [ "dan" ];
            pubkey = "dan:GsdkpETgIbmxpRFMc+7pXU89WrbakP0Row2iz2By+h0=";
          };
        };
      };
    };
    constants = {
      wifi = {
        essid = "MeshOS";
        passwordFile = pkgs.writeText "testpass" "testpass";
        primaryChannel = 2412; # channel 1
        secondaryChannel = 2437; # channel 6
      };
      nebula = {
        caBundle = "/etc/nebula/mesh3/ca.crt";
      };
    };
  };

  baseCfg = (
    { config, modulesPath, ... }:
    let
      pinFile = "/etc/nixpkcs/tpm2.user.pin";
      nebulaNetwork = config.networking.mesh.nebula.networkName;
      nebulaUser = "nebula-${nebulaNetwork}";
      name = config.networking.hostName;
      # We'll need to be able to trade cert files between nodes via scp.
      inherit (import "${modulesPath}/../tests/ssh-keys.nix" pkgs)
        snakeOilPrivateKey
        snakeOilPublicKey
        ;
    in
    {
      imports = [
        self.nixosModules.default
      ];
      networking = {
        firewall.allowedTCPPorts = [ 22 ];
        mesh = {
          plan = meshPlan;
          nebula = {
            tpm2Key = true;
          };
        };
      };

      environment = {
        systemPackages = with pkgs; [
          iw
          nebula
          openssl
          config.services.vwifi.package
        ];
      };

      users.users.root.openssh.authorizedKeys.keys = [ snakeOilPublicKey ];

      services.openssh.enable = true;

      nixpkcs.tpm2.enable = true;
      virtualisation.tpm.enable = true;

      system.activationScripts.initTest.text = ''
        ${lib.optionalString (config.networking.hostName != "airgap") ''
          if [ ! -d /root/.ssh ]; then
            mkdir -p /root/.ssh
            chown 700 /root/.ssh
            cat ${lib.escapeShellArg snakeOilPrivateKey} > /root/.ssh/id_snakeoil
            chown 600 /root/.ssh/id_snakeoil
          fi
        ''}
        if [ ! -f ${lib.escapeShellArg pinFile} ]; then
          mkdir -p /etc/nixpkcs
          echo -n 22446688 > ${lib.escapeShellArg pinFile}
          chmod 0640 ${lib.escapeShellArg pinFile}
          chown root:${lib.escapeShellArg nebulaUser} ${lib.escapeShellArg pinFile} || true
        fi
      '';
    }
  );

  mkNode =
    {
      name,
      id,
      extraConfig ? { },
    }:
    lib.mkMerge [
      baseCfg
      (
        { config, pkgs, ... }:
        {
          networking = {
            hostName = name;
            useNetworkd = true;
            mesh = {
              wifi = {
                enable = true;
                countryCode = "US";
                dedicatedWifiDevices = [ "wlan0" ];
              };
              nebula = {
                enable = true;
                tpm2Key = true;
                localSSHPort = 2222;
                localDNSPort = 5353;
              };
              cache = {
                server.enable = true;
                client = {
                  enable = true;
                  useHydra = false;
                  useRecommendedCacheSettings = true;
                };
              };
            };
            interfaces.eth1.ipv4.addresses = lib.mkForce [
              {
                address = hostAddress id;
                prefixLength = 24;
              }
            ];
          };

          services.vwifi = {
            module = {
              enable = true;
              macPrefix = "52:54:00:12:34:${lib.fixedWidthString 2 "0" (lib.toHexString id)}";
            };
            client = {
              enable = true;
              inherit serverAddress;
            };
          };

          users.users = {
            ${name}.isNormalUser = true;
          };
        }
      )
      extraConfig
      extraMachineOptions
    ];
in
testers.runNixOSTest {
  name = "meshos-mesh";

  nodes = {
    airgap = lib.mkMerge [
      baseCfg
      (
        { config, ... }:
        {
          networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
            {
              address = serverAddress;
              prefixLength = 24;
            }
          ];

          services.vwifi = {
            server = {
              enable = true;
              ports.tcp = 8212;
              ports.spy = 8213;
              openFirewall = true;
            };
          };

          services.harmonia = {
            enable = true;
            signKeyPaths = [
              (pkgs.writeText "airgap.key" ''
                airgap:6o8aSvQhx7ocbhGhx5xRUQdmlnfz+hdy6sMyWxNXtSGu3ZF6UTzE0/W1dGpaaZkQDrJNOFt1o5LUdi04uFvg0w==
              '')
            ];
            settings.priority = 35;
          };

          networking.firewall.allowedTCPPorts = [ 5000 ];
          system.extraDependencies = [ pkgs.emptyFile ];
        }
      )
    ];

    alice = mkNode {
      name = "alice";
      id = 2;
      extraConfig = {
        services.ncps = {
          cache.secretKeyPath = toString (
            pkgs.writeText "alice.key" ''
              alice:B1tm8nqlU2hTntuG5kCyS2Z6m0peLQ6OzW5dht09qQEFuw/YlolSw9d/YXEY3OLjzwBccvP7BVgBKEeu77NRMA==
            ''
          );

          # This is "Hydra" here:
          upstream.caches = lib.mkBefore [ "http://${serverAddress}:5000?priority=1" ];
          upstream.publicKeys = lib.mkBefore [ "airgap:rt2RelE8xNP1tXRqWmmZEA6yTThbdaOS1HYtOLhb4NM=" ];
        };
      };
    };

    bob = mkNode {
      name = "bob";
      id = 3;
      extraConfig = {
        services.ncps.cache.secretKeyPath = toString (
          pkgs.writeText "bob.key" ''
            bob:vMZvFytWqNrcf0JUNi54+JaOdw/g+jyG7UoXnrS19bumunQQ5crNTv+O+L356F57QlURSWDrLLNXlS21n4W9bg==
          ''
        );
      };
    };

    charlie = mkNode {
      name = "charlie";
      id = 4;
      extraConfig = {
        services.ncps.cache.secretKeyPath = toString (
          pkgs.writeText "charlie.key" ''
            charlie:s9wQa1uy4AnlHjWWZXaHWuhOx5L+s9Zls2+D2S0kFNE950sfSN3iJQM37oCaubg0eYnK+iLeZdY8ZbiDkhbuEA==
          ''
        );
      };
    };

    dan = mkNode {
      name = "dan";
      id = 5;
      extraConfig = {
        services.ncps.cache.secretKeyPath = toString (
          pkgs.writeText "dan.key" ''
            dan:0zOXf4iLcqvMSjW86rffUwvKbdlF+trInUNC5obES2Eax2SkROAhubGlEUxz7uldTz1attqQ/RGjDaLPYHL6HQ==
          ''
        );
      };
    };
  };

  testScript =
    { nodes, ... }:
    let
      sshOpts = "-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oIdentityFile=/root/.ssh/id_snakeoil";
      narinfoName =
        (lib.strings.removePrefix "/nix/store/" (
          lib.strings.removeSuffix "-empty-file" pkgs.emptyFile.outPath
        ))
        + ".narinfo";

      narinfoNameChars = lib.strings.stringToCharacters narinfoName;

      narinfoPath =
        node:
        lib.concatStringsSep "/" [
          node.services.ncps.cache.dataPath
          "store/narinfo"
          (lib.lists.elemAt narinfoNameChars 0)
          ((lib.lists.elemAt narinfoNameChars 0) + (lib.lists.elemAt narinfoNameChars 1))
          narinfoName
        ];
    in
    ''
      from shlex import quote as q

      class MeshNode:
        def __init__(self, node, vphy_address, mesh2_address=None, mesh3_address=None, drv_path=None):
          self.node = node
          self.vphy = vphy_address
          self.mesh2 = mesh2_address
          self.mesh3 = mesh3_address
          self.drv = drv_path

        def __getattr__(self, method_name):
          if hasattr(self.node, method_name):
            return getattr(self.node, method_name)
          else:
            return super().__getattr__(method_name)

      # Start everything.
      airgap_node = MeshNode(airgap, '${serverAddress}')
      nodes = (
        MeshNode(alice, '${hostAddress 2}', '10.69.0.1', '10.32.32.32', '${narinfoPath nodes.alice}'),
        MeshNode(bob, '${hostAddress 3}', '10.69.0.2', '10.32.10.2', '${narinfoPath nodes.bob}'),
        MeshNode(charlie, '${hostAddress 4}', '10.69.0.3', '10.32.10.3', '${narinfoPath nodes.charlie}'),
        MeshNode(dan, '${hostAddress 5}', '10.69.0.4', '10.32.10.4', '${narinfoPath nodes.dan}')
      )
      for node in (airgap_node, *nodes):
        node.start()

      # Create the CA.
      mesh3_root = '/etc/nebula/mesh3'
      airgap_node.wait_for_unit("multi-user.target")
      airgap_node.succeed("vwifi-ctrl show >&2")
      airgap_node.wait_until_succeeds(f"test -f {q(mesh3_root)}/airgap.pub")
      airgap_node.succeed(f'nebula-cert ca -curve P256 -name mesh3 -ips 10.32.0.0/16 -pkcs11 "$(nixpkcs-uri mesh3)" -out-crt {q(mesh3_root)}/airgap.crt')

      # Sign all the nodes' certs.
      for node in nodes:
        node.wait_for_unit("multi-user.target")
        node.wait_until_succeeds(f"test -f {q(mesh3_root)}/{q(node.name)}.pub")
        node.succeed(f"scp ${sshOpts} {q(mesh3_root)}/{q(node.name)}.pub root@{q(airgap_node.vphy)}:{q(mesh3_root)}/{q(node.name)}.pub")
        airgap_node.succeed(
          f'nebula-cert sign -ca-crt {q(mesh3_root)}/airgap.crt -in-pub {q(mesh3_root)}/{q(node.name)}.pub -out-crt {q(mesh3_root)}/{q(node.name)}.crt -name {q(node.name)} -pkcs11 "$(nixpkcs-uri mesh3)" -ip {q(node.mesh3)}/16'
        )
        node.succeed(
          f"scp ${sshOpts} root@{q(airgap_node.vphy)}:{q(mesh3_root)}/airgap.crt {q(mesh3_root)}/ca.crt",
          f"scp ${sshOpts} root@{q(airgap_node.vphy)}:{q(mesh3_root)}/{q(node.name)}.crt {q(mesh3_root)}/{q(node.name)}.crt",
          f'chown -R nebula-mesh3:nebula-mesh3 {q(mesh3_root)}',
          'chmod 0755 /etc/nebula',
          'rm -rf /root/.ssh' # Lock it out
        )

      # Check the layer 2 mesh.
      for node in nodes:
        for other_node in nodes:
          node.wait_until_succeeds(f"ping -I mesh2 -c3 {q(other_node.mesh2)} >&2")

      # Check the layer 3 mesh.
      for node in nodes:
        for other_node in nodes:
          node.wait_until_succeeds(f"ping -I mesh3 -c3 {q(other_node.mesh3)} >&2")

      # Now the layer 7 cache.
      for node in nodes:
        for other_node in nodes:
          for mesh in (other_node.mesh2, other_node.mesh3):
            node.wait_until_succeeds(f"curl -f http://{q(mesh)}:8501/ | grep '\"hostname\":\"{q(other_node.name)}\"' >&2")

      # Get the derivation all the way from the first cache on the last node.
      nodes[-1].succeed("nix-store --realise ${lib.escapeShellArg pkgs.emptyFile}")
      nodes[-1].succeed(f'[ "$(cat {q(nodes[-1].drv)} | tee /dev/stderr | grep "Sig:" | wc -l)" == 5 ]')
    '';
}
