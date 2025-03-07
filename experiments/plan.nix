{ pkgs, lib, ... }:
let
  inherit (lib) types;
  inherit (lib.options) mkOption mkEnableOption;
  inherit ((pkgs.callPackage ../lib/net.nix { }).lib) net;
  mkInterfacesOption =
    description:
    mkOption {
      type = with types; listOf str;
      description = "the ${description} interface names";
    };
  mkMetricOption =
    description: metric:
    mkOption {
      type = with types; ints.u16;
      description = "the ${description} interface metric";
      default = metric;
    };
  mkSubnetOption =
    description:
    mkOption {
      type = net.types.cidrv4;
      description = "the ${description} interface address, in CIDR notation";
    };
  mkAddressOption =
    subnet: description:
    mkOption {
      type = net.types.ipv4;
      description = "the ${description} interface address (i.e. the CIDR part before /)";
      default =
        let
          match = builtins.match "([0-9A-Fa-f:.]+)/([0-9]+)" subnet;
        in
        assert match != null;
        net.ip.add 0 (builtins.elemAt match 0);
    };
  mkNetworkOption =
    subnet: description:
    mkOption {
      type = net.types.cidrv4;
      description = "the ${description} interface network (i.e. the subnet with the low bits zeroes)";
      default = net.cidr.subnet 0 0 subnet;
    };
  mkPrefixOption =
    subnet: description:
    mkOption {
      type = with types; ints.u8;
      description = "the ${description} interface prefix (i.e. the CIDR part after /)";
      default = net.cidr.length subnet;
    };
  mkDhcpRangeOption =
    description: what: default:
    mkOption {
      type = with types; ints.u32;
      description = "the ${description} DHCP ${what}";
      inherit default;
    };
  mkV4 =
    description:
    { config, ... }:
    {
      options = {
        subnet = mkSubnetOption description;
        address = mkAddressOption config.subnet description;
        network = mkNetworkOption config.subnet description;
        prefixLength = mkPrefixOption config.subnet description;
        dhcp = {
          start = mkDhcpRangeOption description "start" 100;
          limit = mkDhcpRangeOption description "client count" 100;
        };
      };
    };
  mkV4Option =
    name: description:
    mkOption {
      type = types.submodule (mkV4 name);
      inherit description;
    };
in
{
  router = {
    wan = {
      enable = mkEnableOption "the WAN transport, for WAN connection over ethernet";
      interfaces = mkInterfacesOption "WAN";
      dhcp.enable = mkEnableOption "DHCP for the WAN transport";
      metric = mkMetricOption "WAN" 1000;
    };
    wwan = {
      enable = mkEnableOption "the WWAN transport, for WAN connection to a wireless network";
      interfaces = mkInterfacesOption "WWAN";
      dhcp.enable = mkEnableOption "DHCP for the WWAN transport";
      metric = mkMetricOption "WAN" 1001;
    };
    modem = {
      enable = mkEnableOption "the modem transport, for WAN connection to a cellular modem";
      interfaces = mkInterfacesOption "modem";
      dhcp.enable = mkEnableOption "DHCP for the modem transport";
      metric = mkMetricOption "WAN" 1002;
    };
    management = {
      enable = mkEnableOption "the management transport, for managing the router";
      interfaces = mkInterfacesOption "management";
      v4 = mkV4Option "management";
    };
    lan = {
      enable = mkEnableOption "the LAN transport, for bridging ports on a switch";
      interfaces = mkInterfacesOption "LAN";
      v4 = mkV4Option "LAN";
    };
    guest = {
      enable = mkEnableOption "the guest transport, that can just default route (i.e. not to other mesh peers)";
      interfaces = mkInterfacesOption "guest";
      v4 = mkV4Option "guest";
    };
    mesh = {
      enable = mkEnableOption "the 802.11s mesh transport, for routing traffic over other mesh peers";
      interfaces = mkInterfacesOption "mesh";
      v4 =
        { config, ... }:
        {
          subnet = mkSubnetOption "mesh";
          address = mkAddressOption config.subnet "mesh";
          network = mkNetworkOption config.subnet "mesh";
          prefixLength = mkPrefixOption config.subnet "mesh";
        };
    };
  };

  dns = {
    addresses = mkOption {
      type = with types; attrsOf (listOf str);
      default = { };
      description = "Map of IP addresses to lists of hostnames";
    };
    port = mkOption {
      type = types.port;
      default = 53;
      description = "The DNS port";
    };
    domain = mkOption {
      type = types.str;
      description = "the LAN domain";
      default = "local";
    };
    redirection.enable = mkEnableOption "DNS redirection";
  };

  ntp = {
    port = mkOption {
      type = types.port;
      default = 123;
      description = "The DNS port";
    };
    redirection.enable = mkEnableOption "NTP redirection";
  };
}
