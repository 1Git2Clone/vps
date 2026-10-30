# World 4: Gemstones Lite

<!-- description:
     World 4 on mc4.hu-tao.dev: world 1's close-to-vanilla survival on
     Minecraft 26.3, with a pack trimmed to run on integrated graphics. -->

**Join at** `mc4.hu-tao.dev`
**Pack** [gemstones-lite-26.3.mrpack](https://pages.hu-tao.dev/hutao/vps/mc4/gemstones-lite-26.3.mrpack)
**Minecraft** 26.3

[World 1](mc1.md)'s pack, cut down for a PC with integrated graphics and 8 GB of
RAM, and a version newer: every mod it kept has a 26.3 build. Gameplay is the
same, plus Carry On and Villager in a Bucket from [world 3](mc3.md); what is
gone is everything that costs frames without changing how the game plays.

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
- **Chat stays unreportable**
  ([No Chat Reports](https://modrinth.com/mod/no-chat-reports)).
- Under the hood: Lithium, FerriteCore and Krypton make the server itself
  faster.

## What your pack adds

- **Performance**: Sodium (with Sodium Extra and its options screen),
  ImmediatelyFast, Entity Culling, More Culling, ModernFix, FerriteCore,
  BadOptimizations, Better Block Entities and Dynamic FPS, which throttles the
  game while it is in the background.
- **Interface**: the same as world 1's: VoxelMap, Jade, AppleSkin, Shulker Box
  Tooltip, Mouse Tweaks, Controlling, Zoomify, uku's Armor HUD, More Chat
  History, Better Mount HUD and Mod Menu, plus JEI for every item's recipes
  and uses (R and U on an item).
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
