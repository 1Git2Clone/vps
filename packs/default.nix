# Every world's pack. The key is the pack's directory here and its directory
# on pages; the .mrpack inside is named by `fileName`:
#
#   https://pages.hu-tao.dev/hutao/vps/<key>/<fileName>.mrpack
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
