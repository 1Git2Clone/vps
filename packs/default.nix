# Every world's pack. The key is the pack's directory here and its directory
# on pages; the .mrpack inside is named by `fileName` and the pack's own
# Minecraft version, so a download says which game version it is for:
#
#   https://pages.hu-tao.dev/hutao/vps/<key>/<fileName>-<minecraft>.mrpack
#
# The handbook's links to these are checked against it by packs/mod-list.py.
#
# Read by modules/containers/minecraft.nix (what each server installs) and by
# the flake (the checks, and what pages.yml publishes). See ./mrpack.nix.
{ callPackage }:

let
  pack = dir: fileName: callPackage ./mrpack.nix { inherit dir fileName; };
in
{
  mc1 = pack ./mc1 "gemstones";
  mc2 = pack ./mc2 "gemstones-zombies";
  mc3 = pack ./mc3 "vanilla-plus";
  mc4 = pack ./mc4 "gemstones-lite";
}
