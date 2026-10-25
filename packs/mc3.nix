# ==============================================================================
# mc3's modpack — one .mrpack, for the server AND for the players
# ==============================================================================
# ./mc3 is a packwiz pack, and the single list of what mc3 runs. Every entry
# is pinned to a Modrinth version with its sha512, and carries a side:
#
#   both    on the server and in the players' pack
#   client  players only (shaders, resource packs, sodium, ...)
#   server  the server only (servercore, ...)
#
# This builds the .mrpack from it. modules/containers/minecraft.nix mounts it
# into mc3's container, where itzg installs it and skips every `client` file;
# .forgejo/workflows/pages.yml publishes the SAME file for players to download.
# One build, both consumers: the server and the pack cannot drift apart.
#
# Changing the pack is packwiz, run in ./mc3 (it is in the dev shell):
#
#   packwiz mr add <slug>            add a mod, newest build for this version
#   packwiz update --all             newest builds, same Minecraft version
#   packwiz migrate minecraft <ver>  move to another Minecraft version
#
# then `nix build .#checks.x86_64-linux.mc3-pack` (see `check` below).
#
# WHY NOT `packwiz modrinth export`. It downloads every file to hash it, and
# when a download fails it DROPS that file and still exits 0. In the sandbox
# every download fails, and the result was a valid-looking pack with no mods
# in it. Here each file is a fetchurl pinned by the sha512 packwiz recorded, so
# a dead URL or a changed file fails the build instead.
{
  lib,
  runCommand,
  fetchurl,
  writeText,
  jq,
  zip,
  python3,
}:

let
  dir = ./mc3;
  pack = lib.importTOML (dir + "/pack.toml");
  metaDirs = [
    "mods"
    "resourcepacks"
    "shaderpacks"
  ];
  isMeta = lib.hasSuffix ".pw.toml";

  entries = lib.concatMap (
    d:
    map (
      n:
      let
        m = lib.importTOML (dir + "/${d}/${n}");
      in
      {
        path = "${d}/${m.filename}";
        side = m.side or "both";
        inherit (m.download) url;
        sha512 = m.download.hash;
        src = fetchurl {
          inherit (m.download) url;
          # Store names cannot hold the spaces and commas some packs use.
          name = lib.strings.sanitizeDerivationName m.filename;
          hash = builtins.convertHash {
            inherit (m.download) hash;
            hashAlgo = m.download."hash-format";
            toHashFormat = "sri";
          };
        };
      }
    ) (builtins.filter isMeta (builtins.attrNames (builtins.readDir (dir + "/${d}"))))
  ) metaDirs;

  # Everything else in the pack is a config file the pack ships as-is.
  overrides = lib.fileset.toSource {
    root = dir;
    fileset = lib.fileset.difference dir (
      lib.fileset.unions [
        (dir + "/pack.toml")
        (dir + "/index.toml")
        (lib.fileset.fileFilter (f: isMeta f.name) dir)
      ]
    );
  };

  header = {
    formatVersion = 1;
    game = "minecraft";
    versionId = pack.version;
    inherit (pack) name;
    dependencies = {
      inherit (pack.versions) minecraft;
      fabric-loader = pack.versions.fabric;
    };
  };

  entriesTsv = writeText "mc3-entries.tsv" (
    lib.concatMapStrings (e: "${e.path}\t${e.url}\t${e.side}\t${e.src}\t${e.sha512}\n") entries
  );

  mrpack =
    runCommand "vanilla-plus.mrpack"
      {
        nativeBuildInputs = [
          jq
          zip
        ];
        passthru = { inherit check; };
      }
      ''
        mkdir -p pack/overrides
        cp -r ${overrides}/. pack/overrides/
        chmod -R u+w pack

        # The mrpack format wants sha1 and the size as well, which packwiz does
        # not record; the fetched file is right here to take them from.
        while IFS=$'\t' read -r path url side src sha512; do
          jq -n \
            --arg path "$path" --arg url "$url" --arg side "$side" --arg sha512 "$sha512" \
            --arg sha1 "$(sha1sum "$src" | cut -d' ' -f1)" \
            --argjson size "$(stat -c %s "$src")" \
            '{path: $path,
              hashes: {sha1: $sha1, sha512: $sha512},
              env: {client: (if $side == "server" then "unsupported" else "required" end),
                    server: (if $side == "client" then "unsupported" else "required" end)},
              downloads: [$url],
              fileSize: $size}'
        done < ${entriesTsv} \
          | jq -s --argjson head ${lib.escapeShellArg (builtins.toJSON header)} '$head + {files: .}' \
          > pack/modrinth.index.json

        n=$(jq '.files | length' pack/modrinth.index.json)
        if [ "$n" -ne ${toString (builtins.length entries)} ]; then
          echo "mc3 pack: $n files in the index, ${toString (builtins.length entries)} in the pack" >&2
          exit 1
        fi

        cd pack
        find . -exec touch -h -d @315532800 {} +
        zip -qrXD $out modrinth.index.json overrides
      '';

  # Every hard `depends` in every jar's fabric.mod.json, nested jars included,
  # against what each SIDE actually gets. Modrinth's own dependency data is not
  # enough: world 2's first start failed on geckolib, which vics-point-blank
  # requires in its jar and declares nowhere on Modrinth. A mod whose library is
  # server-only crashes every player's client on launch, and the reverse stops
  # the server, so both sides are checked. It needs no network: the jars are the
  # same fetchurl outputs the pack is built from.
  check =
    runCommand "mc3-pack-check"
      {
        nativeBuildInputs = [ python3 ];
        jars = builtins.toJSON (
          map (e: {
            inherit (e) path side;
            src = "${e.src}";
          }) (builtins.filter (e: lib.hasPrefix "mods/" e.path) entries)
        );
        passAsFile = [ "jars" ];
      }
      ''
        python3 -I ${../tests/mc3-pack-deps.py} "$jarsPath" \
          ${pack.versions.minecraft} ${pack.versions.fabric}
        touch $out
      '';
in
mrpack
