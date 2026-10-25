# How the servers are set up

Three Fabric servers, one public port, and one modpack per world that is both
what the server runs and what players install.

## The pieces

| Piece            | Where                                  | Does                                                                                      |
| ---------------- | -------------------------------------- | ----------------------------------------------------------------------------------------- |
| mc-router        | `modules/containers/mc-router.nix`     | owns 25565, reads the hostname the player typed, routes to that world, wakes it if asleep |
| minecraft-scaler | `modules/containers/minecraft-cap.nix` | turns mc-router's wake/sleep webhook into `systemctl start`/`stop`; refuses a third world |
| the worlds       | `modules/containers/minecraft.nix`     | one `itzg/minecraft-server` container each, on its own volume, RCON on loopback only      |
| the packs        | `packs/mc1`, `packs/mc2`, `packs/mc3`  | each world's mods, pinned, with the side each one runs on                                 |
| the pack build   | `packs/mrpack.nix`                     | turns a pack into one `.mrpack`, plus the dependency check                                |
| the downloads    | `.forgejo/workflows/pages.yml`         | publishes the same `.mrpack` files on pages                                               |

Waking, sleeping, the cap of two and the whitelist-gated wake are described in
[Worlds on demand](../architecture/services.md#worlds-on-demand-at-most-two-at-once);
the heap settings in
[Why the Minecraft heap is two numbers](../architecture/services.md#why-the-minecraft-heap-is-two-numbers).

## One pack, two consumers

```text
packs/mc1/                 a packwiz pack: one .pw.toml per mod, each pinning an
  pack.toml                exact Modrinth version, its sha512 and its side
  mods/*.pw.toml
  config/...               client config files
      │
      ▼  packs/mrpack.nix
gemstones.mrpack
      ├──▶ mounted into the world's container; itzg installs it (TYPE=MODRINTH)
      └──▶ published on pages; players import it into their launcher
```

Because both come from one build of one directory, the server and the players'
pack cannot disagree about a mod both sides need. Before this, world 2's server
picked the newest build of each mod at every start while players kept a pack
from weeks earlier; when the packs were introduced, the zombie-horde mod was at
2.0.0 on the server and 1.2.0 in the players' pack.

### The `.mrpack` format

A `.mrpack` is a zip holding `modrinth.index.json` (every file, with its
download URL, sha1, sha512, size and which sides need it) and optional
`overrides/`, `client-overrides/` and `server-overrides/` folders copied into
the game directory. The specification is Modrinth's:
[Modrinth Modpack format (.mrpack)](https://support.modrinth.com/en/articles/8802351-modrinth-modpack-format-mrpack).

Two of its fields carry this setup:

- **`env`** on each file says whether the client and the server need it. itzg
  skips every file marked `server: unsupported` (checked in
  `mc-image-helper`'s `FileInclusionCalculator`), so client-only mods such as
  Sodium never reach a server.
- **`client-overrides/`** is where the packs' config files go. itzg extracts
  `overrides/` and `server-overrides/` into the server's `/data`, but never
  `client-overrides/`, so a player's `lithium.properties` cannot quietly
  reconfigure a live server. Server config is the server's own.

### packwiz

The packs are kept with [packwiz](https://packwiz.infra.link/), which stores a
pack as plain TOML files that diff well and does the version work: adding a mod
with its dependencies, updating everything, and moving to a new Minecraft
version. How to use it here is in [Working on the packs](packs.md).

packwiz is not what builds the `.mrpack`, though. `packwiz modrinth export`
downloads every file to hash it and, when a download fails, drops that file and
still exits 0; inside the Nix sandbox every download fails, and the result was
a valid-looking pack with no mods in it. `packs/mrpack.nix` fetches each file
itself, pinned by the sha512 packwiz recorded, so a dead link or a changed file
fails the build instead. The first build on a machine downloads every file in
the pack (about 300 MB for mc3), then they are in the Nix store.

### Byte-for-byte reproducible

The `.mrpack` is built with a sorted file list, fixed modes and timestamps and
no extra zip fields, so the same commit gives the same bytes on any machine.
That makes "is the download the same as the server's pack" a hash comparison.
It was not at first: `zip -r` takes files in the filesystem's directory order,
which differed between CI and a desktop.

## The dependency check

`checks.x86_64-linux.mc<N>-pack` opens every mod jar in the pack, including the
jars nested inside other jars, and checks every hard `depends` in its
`fabric.mod.json` against what each side actually gets. Modrinth's dependency
data is not enough: world 2's first start failed on geckolib, which
vics-point-blank requires in its jar and declares nowhere on Modrinth. A mod
whose library is server-only crashes every player's launch, and the reverse
stops the server, so both sides are checked. It runs offline, on the same
pinned downloads the pack is built from, as a pre-commit hook and in CI.

Version ranges are not evaluated, only presence: a mismatch names itself in the
server log, while a missing mod is a crash on every player's launch.
