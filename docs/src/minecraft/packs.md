# Working on the packs

Each world's pack is a [packwiz](https://packwiz.infra.link/) directory under
`packs/`. packwiz is in the dev shell, and every command runs inside the pack's
directory. For how the pack becomes the server and the download, see
[How the servers are set up](servers.md).

```sh
nix develop
cd packs/mc1
```

## What a mod looks like

One file per mod, in `mods/` (or `resourcepacks/`, `shaderpacks/`):

```toml
name = "Waystones"
filename = "waystones-fabric-26.2-26.2.0.12.jar"
side = "both"                 # both | client | server

[download]
url = "https://cdn.modrinth.com/data/LOpKHB2A/versions/HUacBshD/..."
hash-format = "sha512"
hash = "8df1076c…"            # the exact file; the build fails if it changes

[update.modrinth]
mod-id = "LOpKHB2A"           # the Modrinth project
version = "HUacBshD"          # the exact version pinned
```

- **`side`** decides who gets it. `both` is the server and players, `client`
  players only, `server` the server only. packwiz takes it from Modrinth's tags,
  which are sometimes wrong for us; edit it by hand when they are.
- **`pack.toml`** holds the Minecraft and Fabric loader versions.
- **`index.toml`** is packwiz's hash of every file in the pack. It is generated:
  never edit it, and the `packwiz-refresh` hook rewrites it on commit.
- **Everything else** (`options.txt`, `config/...`) is client config, shipped in
  the pack's `client-overrides/` and never applied to the server.
- **Every pack is shared** (`shared` in `packs/default.nix`), so
  preferences live under `config/yosbr/`, mirroring the game folder:
  `config/yosbr/config/sodium-options.json` is a player's starting
  `config/sodium-options.json`. The YOSBR mod copies each into place only
  when the player has no file of their own. A plain override is different: on
  every update Prism deletes the files the old pack shipped and writes the new
  pack's over the player's, so a bundled `sodium-options.json` resets their
  video settings each time. Only mod internals and compatibility fixes stay
  plain overrides, listed in `enforced`; the build fails on anything else.
  A pack ships no `options.txt` of its own: settings belong in
  `packs/options`, which only the `-with-options` builds carry.

## Everyday changes

| You want to…                       | Run                                     | Then                                                        |
| ---------------------------------- | --------------------------------------- | ----------------------------------------------------------- |
| add a mod                          | `packwiz mr add <slug>`                 | check the `side` packwiz chose, and its dependencies' sides |
| add a specific version             | `packwiz mr add <modrinth version URL>` | same                                                        |
| remove a mod                       | `packwiz remove <name>`                 | remove libraries nothing else needs                         |
| update everything, same MC version | `packwiz update --all`                  | read the diff: every changed pin is a change on the server  |
| move to another Minecraft version  | `packwiz migrate minecraft <ver>`       | it lists mods with no build for the new version             |
| change a client config             | edit the file                           | the hook refreshes `index.toml`                             |

`packwiz mr add` and `update` pick the newest build for the pack's Minecraft
version. Pinning a particular version is the version-page URL,
`https://modrinth.com/mod/<project>/version/<version id>`.

## Staying current

Renovate cannot see Modrinth, so `.forgejo/workflows/mods.yml` runs
`packs/outdated.sh` every day at 06:00 UTC. It runs `packwiz update --all` on a
copy of each pack and fails if any mod has a newer build for that pack's
Minecraft version, listing each one with its side:

```text
mc3  both    "FarmersDelight-26.2-3.6.28+refabricated.jar" -> "FarmersDelight-26.2-3.6.30+refabricated.jar"
```

A red run is answered one of two ways, in a commit:

- **take it:** `packwiz update <name>` (or `--all`), then the usual checks. A
  `both` or `server` line changes the server, so ship it like any mod change.
- **hold it back:** `packwiz pin <name>` writes `pin = true` into that mod's
  `.pw.toml`, and update skips it from then on. `packwiz unpin <name>` lets it
  move again. Say why in the commit, since the pin itself cannot.

Run it by hand with `nix develop .#ci -c packs/outdated.sh`; it never touches
the tree.

## Before committing

The pre-commit hooks do both checks; to run them by hand:

```sh
packs/refresh.sh                                   # packwiz refresh in every pack
nix build .#checks.x86_64-linux.mc1-pack -L        # mc2-pack, mc3-pack
```

The dependency check prints how many mods each side gets and names any mod
whose required library is missing on a side, for example:

```text
client: mods/tectonic-3.0.28-fabric-26.2.jar needs lithostitched *
```

The Option packs workflow boots each built options pack with its pinned
server-side mods and Fabric loader,
then waits for Minecraft's `Done` line. The startup test skips mc1's Dlaw
Discord integration because it needs a real bot token and waits for Discord;
all other server mods are loaded together. This catches startup crashes from
mod interactions that a dependency graph cannot detect. See
[CI and validation](../operations/ci.md) for what the check covers, how to run
a single world, and the build and boot commands for all four worlds.

That one was real: Modrinth marks lithostitched server-only, but tectonic and
Terralith need it on the client too, so `packs/mc3/mods/lithostitched.pw.toml`
says `side = "both"`. An update can reset a side you set by hand; the check is
what catches it.

A pack with an `options.txt` is also checked for the resource packs it turns
on. Minecraft drops a `resourcePacks` entry it cannot find without a word, so
an update that renames a zip turns that pack off for every player:

```text
resourcePacks: file/FreshAnimations_v1.10.5.zip is not a file in resourcepacks/
```

Write the entry as `file/` plus the `filename` from its `.pw.toml`, or
`<mod id>:<folder>` for a mod's built-in pack (`punchy:punchy`). A pack made
for another Minecraft version also has to be listed in
`incompatibleResourcePacks`, or the game drops it as well; the check cannot
see that one, so look in the game log for "no longer compatible".

## Packs with options

Every pack has a second build, `<pack>-<minecraft>-with-options.mrpack`: the
same mods with the settings in `packs/options` laid over it, so a fresh import
starts with those. They are hutao's, and preferences rather than anything a
world needs, so the plain pack stays the default and the world pages link
both.

```text
packs/options/
  all/options.txt     every pack: only the keys you set
  all/config/...      every pack: whole mod config files
  mc4/options.txt     one pack, applied after all/
  mc4/config/...
```

`packs/options.py` applies them, `all/` first and then the pack's own folder,
the later winning:

- **`options.txt` merges key by key**, over the pack's own `options.txt` if it
  ships one. A key you leave out keeps Minecraft's default or the pack's, and a
  key a pack's mods do not know is ignored, so one file serves every pack.
  Lines without a `:` are comments.
- **Every other file replaces the pack's whole.** Mod configs are JSON, TOML
  and `.properties` that change shape between mod versions; a key merge of
  those is guesswork, a replacement is what you wrote. To change one setting
  for one pack, copy the file into that pack's folder and edit it there.

The result goes under `config/yosbr/`, so it is where a player starts and
never what an update writes over their own. World 3's resource packs, shader
choice and shader settings are in `packs/options/mc3`: the plain world 3 pack
ships those packs but turns none of them on.

`option-packs.yml` on both Forgejo and GitHub builds the affected worlds,
boots those outputs' Fabric servers, then uploads them as the run's `option-packs`
artifact. A failed boot prevents the upload. Changes under `packs/mcN/` select
that world; shared pack code or any option override selects all four. The
artifact contains only the selected worlds. That is the fork path: change `packs/options`,
push, and download your packs from the run. It does not publish: `pages-pull`
serves only the newest `pages` artifact, so `pages.yml` stages the same builds
next to the plain packs. Locally:

```sh
nix build .#mc4-mrpack-with-options
```

## Changing a live world's mods

A pack change reaches the server on the world's next start: itzg re-syncs the
mods to the pack, removing what left it. Players have to re-import the pack at
the same time, so for a mod both sides need, tell them before the deploy.

Prism's update removes every file the previous pack installed, before writing
the new one. A player whose instance began as their own export (configs,
`options.txt`, waypoints and screenshots in its overrides) loses all of those
on the first update. Have them update a fresh import of the published pack,
or copy those files out first.

- **Server-only or client-only changes** are safe on their own: players are
  unaffected by the first, the server by the second.
- **A new worldgen mod** only shapes chunks generated after it arrives, and can
  leave visible seams against old terrain. Some, like The Lost Cities, cannot
  be added to an existing world at all.
- **Moving a world's Minecraft version** is a one-way trip for the world:
  back up first (the weekly snapshot, or by hand), and check the image's Java
  version matches (26.x is `java25`, 1.21.1 is `java21`).

When worlds 1 and 2 were converted from slug lists to packs, every server-side
pin was taken from the jars already on the box, looked up on Modrinth by sha1
(`POST /v2/version_files`), so the conversion installed nothing new. Mods not
on a server were set `side = "client"`, so the client pack's extras did not
leak onto the server.

## Shipping it

1. Commit; the hooks run the checks.
2. Deploy (see [Deploying](../operations/deploying.md)). A world that is up
   restarts with the new pack; a sleeping one picks it up when it wakes.
3. Push `main`. The pages workflow rebuilds the packs and publishes them, and
   since the build is reproducible the published file is byte-identical to the
   server's. A pack's file name ends in its Minecraft version, so moving a pack
   to a new version moves its link too; the mod-lists hook fails until every
   link in the handbook says the new name:

```sh
nix build --print-out-paths .#mc1-mrpack | xargs sha256sum
curl -s https://pages.hu-tao.dev/hutao/vps/mc1/gemstones-26.1.2.mrpack | sha256sum
```

## A new world

A pack (`packwiz init` in a new `packs/mc<N>`, then add it to
`packs/default.nix`), a container in `modules/containers/minecraft.nix`, an
entry in `worlds` there, a MAPPING line in `modules/containers/mc-router.nix`,
a page in `docs/src/minecraft/worlds/` that includes the generated
`mc<N>-mods.md`, an RCON secret in `modules/secrets.nix` and `secrets.yaml`,
the hostname in
`tofu/modules/cloudflare-dns/variables.tf`, and the pack in the `mrpacks` hook
and `pages.yml`'s list. The backup, the cap and the scaler follow `worlds`.
