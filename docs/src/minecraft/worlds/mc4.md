# World 4: Gemstones Lite

<!-- description:
     World 4 on mc4.hu-tao.dev: world 1's close-to-vanilla survival on
     Minecraft 26.3, with a pack trimmed to run on integrated graphics. -->

**Join at** `mc4.hu-tao.dev`
**Pack** [mc4.hu-tao.dev-26.3.mrpack](https://pages.hu-tao.dev/hutao/vps/mc4/mc4.hu-tao.dev-26.3.mrpack)
**With options** [mc4.hu-tao.dev-26.3-with-options.mrpack](https://pages.hu-tao.dev/hutao/vps/mc4/mc4.hu-tao.dev-26.3-with-options.mrpack)
**Minecraft** 26.3

[World 1](mc1.md)'s pack, cut down for a PC with integrated graphics and 8 GB of
RAM, and a version newer: every mod it kept has a 26.3 build. Gameplay is the
same, plus a handful of conveniences from [world 3](mc3.md); what is gone is
everything that costs frames without changing how the game plays.

## What changes for everyone

- **Trees fall** ([FallingTree](https://modrinth.com/mod/fallingtree)): cut one
  log and the whole tree comes down.
- **Half the players can skip the night**
  ([Server Sleep](https://modrinth.com/mod/serversleep)): once 50% are in bed,
  morning comes.
- **Carry things**: [Carry On](https://modrinth.com/mod/carry-on): sneak and
  right-click with an empty hand to pick up a mob or a chest with its
  contents, and carry it.
  [Villager in a Bucket](https://modrinth.com/mod/villager-in-a-bucket):
  right-click a villager, wandering trader or zombie villager with an empty
  bucket to carry it as an item, trades and all.
- **Bases keep going while you are away**
  ([Unloaded Activity](https://modrinth.com/mod/unloaded-activity)): crops,
  furnaces and the like in chunks nobody was near catch up when they load
  again. It counts server time only: an asleep world has no time passing, so
  after the last player leaves it covers the 20 minutes before the world
  sleeps. Server-only; nothing to install.
- **Ore Vein Miner** mines a connected vein of ore at once: sneak while you
  break one with a pickaxe.
- **Clumps** merges XP orbs.
- **Chat stays unreportable**
  ([No Chat Reports](https://modrinth.com/mod/no-chat-reports)).
- Under the hood: Lithium, FerriteCore, Krypton, C2ME, ScalableLux,
  ServerCore, Ksyxis and Alternate Current (for redstone) make the server
  itself faster, as on world 3.

## What your pack adds

- **Performance**: Sodium (with Sodium Extra and its options screen),
  ImmediatelyFast, Entity Culling, More Culling, ModernFix, FerriteCore,
  BadOptimizations, Better Block Entities and Dynamic FPS, which throttles the
  game while it is in the background.
- **Interface**: Xaero's Minimap and World Map, Jade, AppleSkin, Shulker Box
  Tooltip, Mouse Tweaks, Controlling, Ok Zoomer, uku's Armor HUD, Chat Heads,
  More Chat History, Better Mount HUD and Mod Menu, plus JEI for every item's
  recipes and uses (R and U on an item).
- **Conveniences**: Freecam, FastQuit (back to the menu without waiting for
  the save) and No Telemetry.
- **Visuals**: only 3D Skin Layers.

## What is left out, and why

| Left out                                         | Why                                                                                  |
| ------------------------------------------------ | ------------------------------------------------------------------------------------ |
| Voxy and its server side                         | distant terrain is the heaviest thing in world 1's pack, in video memory and on disk |
| Iris                                             | integrated graphics cannot run shaders                                               |
| Sound Physics Remastered                         | traces every sound through the terrain, on the CPU                                   |
| LambDynamicLights                                | re-lights the area around every moving light, every frame                            |
| BetterGrassify, Sodium Shadowy Path Blocks       | purely cosmetic                                                                      |
| EMF, ETF, Continuity, OptiGUI, Skyboxify, Puzzle | they drive resource pack features, and the pack ships no resource packs              |
| the Discord integration                          | world 1's alone                                                                      |
| Borderless Mining                                | it has no 26.3 build                                                                 |

## Tips

- If the game stutters, lower _Render Distance_ in Sodium's video settings
  first; 8 is a good start on integrated graphics.
- Every key is in _Options_ → _Controls_; Controlling's search finds them.

## Every mod

{{#include mc4-mods.md}}
