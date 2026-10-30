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
  pack =
    dir: fileName: extra:
    callPackage ./mrpack.nix ({ inherit dir fileName; } // extra);

  # Mod internals and compatibility fixes: these follow the pack, so they
  # stay plain overrides on a shared pack. Everything else is a default.
  enforced = [
    "config/fabric_loader_dependencies.json"
    "config/ferritecore.mixin.properties"
    "config/forgeconfigapiport.toml"
    "config/lithium.properties"
    "config/modernfix-mixins.properties"
    "config/sodium-extra.properties"
    "config/sodium-mixins.properties"
  ];
in
{
  mc1 = pack ./mc1 "gemstones" {
    shared = true;
    enforced = enforced ++ [ "config/iris-excluded.json" ];
  };
  mc2 = pack ./mc2 "gemstones-zombies" { shared = true; };
  # World 3 is played by its owner alone, who keeps the pack's options.txt
  # and configs as the settings to come back to on every update.
  mc3 = pack ./mc3 "vanilla-plus" { };
  mc4 = pack ./mc4 "gemstones-lite" {
    shared = true;
    inherit enforced;
  };
}
