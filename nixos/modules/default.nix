/**
  MeshOS - Copyright (C) 2024+ MeshOS Contributors
  SPDX-License-Identifier: LGPL-3.0-or-later
  Authors:
    Andrew Brooks <andrewgrantbrooks@gmail.com>
    Morgan Jones <me@numin.it>
*/

{ nixpkcs, ... }@flakeInputs:

{ lib, ... }:

let
  inherit (lib.lists) map;
  loadSubmodule = path: import path flakeInputs;
in
{
  imports =
    [ nixpkcs.nixosModules.default ]
    ++ map loadSubmodule [
      ./80211s.nix
      ./plan.nix
      ./wifi.nix
      ./nebula.nix
      ./caches.nix
    ];
}
