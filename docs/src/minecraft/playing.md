# Playing

Four worlds share one address, and each has a modpack you install once. The
pack is exactly what the server runs, plus the client-side mods that make it
look and run better, so a pack from here can always join its world.

| World                    | Join at          | Minecraft | What it is                                           | Pack                                                                                                      |
| ------------------------ | ---------------- | --------- | ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| [world 1](worlds/mc1.md) | `mc.hu-tao.dev`  | 26.1.2    | the main survival world                              | [gemstones-26.1.2.mrpack](https://pages.hu-tao.dev/hutao/vps/mc1/gemstones-26.1.2.mrpack)                 |
| [world 2](worlds/mc2.md) | `mc2.hu-tao.dev` | 1.21.1    | zombies: hordes, mutants, guns, bunkers              | [gemstones-zombies-1.21.1.mrpack](https://pages.hu-tao.dev/hutao/vps/mc2/gemstones-zombies-1.21.1.mrpack) |
| [world 3](worlds/mc3.md) | `mc3.hu-tao.dev` | 26.2      | Vanilla+: new biomes, structures and animals         | [vanilla-plus-26.2.mrpack](https://pages.hu-tao.dev/hutao/vps/mc3/vanilla-plus-26.2.mrpack)               |
| [world 4](worlds/mc4.md) | `mc4.hu-tao.dev` | 26.3      | world 1's pack, light enough for integrated graphics | [gemstones-lite-26.3.mrpack](https://pages.hu-tao.dev/hutao/vps/mc4/gemstones-lite-26.3.mrpack)           |

`minecraft.hu-tao.dev` and the server's bare IP also reach world 1. Each
world's page says what its mods do and lists every one of them.

## Installing a pack

A `.mrpack` is a Modrinth modpack: a small file listing the mods, which your
launcher downloads from Modrinth and checks. Any launcher that imports Modrinth
packs works; these two are the usual ones.

- **[Prism Launcher](https://prismlauncher.org/)**: _Add Instance_ → _Import_,
  then paste the pack's link (or pick the downloaded file).
- **[Modrinth App](https://modrinth.com/app)**: download the pack, then drag it
  onto the app, or use _Import from file_ when creating an instance.

Modrinth's own guide covers the same steps with screenshots:
[Modpacks on Modrinth](https://support.modrinth.com/en/articles/8802250-modpacks-on-modrinth).

The links never change. When a pack is updated, the same link serves the new
version: import it again (or update the instance) and you match the server.

## Joining

You need to be on the world's whitelist; ask for it. Then add the address from
the table as a server and join.

**Worlds sleep when nobody is on**, to save the server's memory. If the server
list says _Asleep. Join to wake it up_, join anyway: that wakes it. The first
attempt may time out after about 30 seconds: that is the world starting, not
your connection. A minute or two later, join again. A world goes back to sleep
ten minutes after the last player leaves. At most two worlds are awake at once,
so if two others are busy, the third waits its turn.

## Something is wrong

- **The game crashes on launch, or the server says a mod is missing or the
  wrong version**: your pack is out of date. Import the pack from its link
  again.
- **"You are not whitelisted on this server"**: ask to be added.
- **A world will not wake** while two others are up: that is the limit, not a
  fault.
