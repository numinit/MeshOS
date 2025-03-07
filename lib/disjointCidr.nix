{
  lib ? null,
  ...
}:

let
  net =
    (import ./net.nix {
      inherit lib;
    }).lib.net;

  # Generates CIDRs from the specified root with the given number of bits.
  # Called recursively.
  generateDisjointCidrsFrom =
    root: bits: exclude:
    let
      length = net.cidr.length root;
      length' = length + 1;
      left = net.cidr.make length' (net.cidr.host 0 root);
      right = net.cidr.make length' (net.cidr.host ((net.cidr.capacity root) - 1) root);
      isExcluded = excluded: builtins.any (x: net.cidr.child x root) excluded;
      isEqual = excluded: builtins.any (x: x == root) excluded;
    in
    if length < bits && !(isEqual exclude) && (isExcluded exclude) then
      # Recursive case
      (generateDisjointCidrsFrom left bits exclude) ++ (generateDisjointCidrsFrom right bits exclude)
    else if isEqual exclude then
      # Internal node, and it's one of the excluded.
      [ ]
    else
      # Internal node, and it's not one of the excluded.
      [ root ];
in
{
  # Generates all CIDRs disjoint from the specified list of excluded ranges.
  # Usage: generateDisjointCidrs ["1.2.3.4/32" "192.168.0.0/16"]
  generateDisjointCidrs =
    exclude:
    let
      excluded = map (x: net.cidr.add 0 x) exclude;
      isIpv6 = x: (builtins.match ".*:.*" x) != null;
      ipv6 =
        builtins.any isIpv6 excluded
        && ((builtins.all isIpv6 excluded) || throw "All addresses must be IPv6");
      prefix = if ipv6 then "::/0" else "0.0.0.0/0";
      bits = if ipv6 then 128 else 32;
      result = generateDisjointCidrsFrom prefix bits excluded;
    in
    builtins.sort (
      x: y:
      let
        xLen = net.cidr.length x;
        yLen = net.cidr.length y;
        xHost = net.cidr.host 0 x;
        yHost = net.cidr.host 0 y;
      in
      if xLen < yLen then
        true
      else if xLen > yLen then
        false
      else
        net.ip.diff xHost yHost < 0
    ) result;
}
