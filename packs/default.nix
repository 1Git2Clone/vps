# Every world's pack. The key is the pack's directory here and its directory
# on pages; the .mrpack inside is named by `fileName` and the pack's own
# Minecraft version, so a download says which game version it is for:
#
#   https://pages.hu-tao.dev/hutao/vps/<key>/<fileName>-<minecraft>.mrpack
#
# Each pack also has a `withOptions` build, the same pack with the options in
# ./options laid over it (./options/all, then ./options/<key> if it exists),
# published beside it as <fileName>-<minecraft>-with-options.mrpack. Fork the
# repo and change ./options to build your own. See packs/options.py.
#
# The handbook's links to these are checked against it by packs/mod-list.py.
#
# Read by modules/containers/minecraft.nix (what each server installs) and by
# the flake (the checks, and what pages.yml publishes). See ./mrpack.nix.
{ callPackage }:

let
  pack =
    key: fileName: extra:
    let
      args = {
        dir = ./. + "/${key}";
        inherit fileName;
        options = [ ./options/all ] ++ (if builtins.pathExists perPack then [ perPack ] else [ ]);
      }
      // extra;
      perPack = ./options + "/${key}";
    in
    callPackage ./mrpack.nix args
    // {
      withOptions = callPackage ./mrpack.nix (args // { withOptions = true; });
    };

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
  mc1 = pack "mc1" "gemstones" {
    shared = true;
    enforced = enforced ++ [ "config/iris-excluded.json" ];
  };
  mc2 = pack "mc2" "gemstones-zombies" { shared = true; };
  # World 3's own settings now live in ./options (they are the global ones),
  # so its plain pack, like the others, starts players from the mods' defaults.
  mc3 = pack "mc3" "vanilla-plus" {
    shared = true;
    enforced = [
      "config/fabric/indigo-renderer.properties"
      "config/ferritecore.mixin.properties"
      "config/iris-excluded.json"
      "config/lithium.properties"
      "config/sodium-mixins.properties"
    ];
  };
  mc4 = pack "mc4" "gemstones-lite" {
    shared = true;
    inherit enforced;
  };
}
