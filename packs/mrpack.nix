# ==============================================================================
# A world's modpack — one .mrpack, for the server AND for the players
# ==============================================================================
# Each world's directory here (./mc1, ./mc2, ./mc3) is a packwiz pack, and the
# single list of what that world runs. Every entry is pinned to a Modrinth
# version with its sha512, and carries a side:
#
#   both    on the server and in the players' pack
#   client  players only (sodium, shaders, resource packs, minimaps, ...)
#   server  the server only (servercore, dlaw, ...)
#
# This builds the .mrpack from one of them. modules/containers/minecraft.nix
# mounts it into that world's container, where itzg installs it and skips every
# `client` file; .forgejo/workflows/pages.yml publishes the SAME file for
# players to download. One build, both consumers: the server and the pack
# cannot drift apart.
#
# Every other file in the directory (options.txt, config/...) goes into the
# pack's `client-overrides/`, NOT `overrides/`. itzg extracts `overrides/` into
# the server's /data, so a client's lithium.properties there would quietly
# reconfigure a live server; `client-overrides/` it never reads. Server config
# is the server's own.
#
# Changing a pack is packwiz, run in its directory (it is in the dev shell):
#
#   packwiz mr add <slug>            add a mod, newest build for this version
#   packwiz update --all             newest builds, same Minecraft version
#   packwiz migrate minecraft <ver>  move to another Minecraft version
#
# The pre-commit hooks then refresh packwiz's index and run `check` below.
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
  # The packwiz directory, and the name of the .mrpack built from it, before
  # the -<minecraft version> the build appends.
  dir,
  fileName,
}:

let
  pack = lib.importTOML (dir + "/pack.toml");
  metaDirs = builtins.filter (d: builtins.pathExists (dir + "/${d}")) [
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

  # Everything else in the pack is a client config file, shipped as-is.
  configFiles = lib.fileset.difference dir (
    lib.fileset.unions [
      (dir + "/pack.toml")
      (dir + "/index.toml")
      (lib.fileset.fileFilter (f: isMeta f.name) dir)
    ]
  );
  clientOverrides =
    if lib.fileset.toList configFiles == [ ] then
      null
    else
      lib.fileset.toSource {
        root = dir;
        fileset = configFiles;
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

  entriesTsv = writeText "${fileName}-entries.tsv" (
    lib.concatMapStrings (e: "${e.path}\t${e.url}\t${e.side}\t${e.src}\t${e.sha512}\n") entries
  );

  mrpack =
    runCommand "${fileName}-${pack.versions.minecraft}.mrpack"
      {
        nativeBuildInputs = [
          jq
          zip
        ];
        passthru = { inherit check; };
      }
      ''
        mkdir -p pack
        ${lib.optionalString (clientOverrides != null) ''
          mkdir -p pack/client-overrides
          cp -r ${clientOverrides}/. pack/client-overrides/
        ''}
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
          echo "${fileName}: $n files in the index, ${toString (builtins.length entries)} in the pack" >&2
          exit 1
        fi

        # Byte-for-byte reproducible, so the players' download and the server's
        # copy can be compared by hash. `zip -r` takes files in readdir order,
        # which differs between filesystems: CI's build and a desktop's had
        # the same files in a different order. So: a sorted list, fixed modes
        # and times, no extra fields (-X) and no directory entries (-D).
        cd pack
        find . -type f -exec chmod 0644 {} +
        find . -exec touch -h -d @315532800 {} +
        find . -type f | sed 's|^\./||' | LC_ALL=C sort | zip -qXD $out -@
      '';

  # Every hard `depends` in every jar's fabric.mod.json, nested jars included,
  # against what each SIDE actually gets. Modrinth's own dependency data is not
  # enough: world 2's first start failed on geckolib, which vics-point-blank
  # requires in its jar and declares nowhere on Modrinth. A mod whose library is
  # server-only crashes every player's client on launch, and the reverse stops
  # the server, so both sides are checked. It needs no network: the jars are the
  # same fetchurl outputs the pack is built from.
  check =
    runCommand "${fileName}-check"
      {
        nativeBuildInputs = [ python3 ];
        jars = builtins.toJSON (
          map (e: {
            inherit (e) path side;
            src = "${e.src}";
          }) (builtins.filter (e: lib.hasPrefix "mods/" e.path) entries)
        );
        files = builtins.toJSON (
          map (e: {
            inherit (e) path;
            src = "${e.src}";
          }) entries
        );
        passAsFile = [
          "jars"
          "files"
        ];
      }
      (
        ''
          python3 -I ${../tests/mrpack-deps.py} "$jarsPath" \
            ${pack.versions.minecraft} ${pack.versions.fabric}
        ''
        # options.txt turns resource packs on by file name, and Minecraft
        # silently drops a name it cannot find. See tests/mrpack-options.py.
        + lib.optionalString (builtins.pathExists (dir + "/options.txt")) ''
          python3 -I ${../tests/mrpack-options.py} "$filesPath" ${dir + "/options.txt"} ${
            lib.optionalString (builtins.pathExists (dir + "/resourcepacks")) "${dir + "/resourcepacks"}"
          }
        ''
        + "touch $out"
      );
in
mrpack
