# World 1: Gemstones

<!-- description:
     World 1 on mc.hu-tao.dev: close-to-vanilla survival on Minecraft
     26.1.2. What the server changes, what the Gemstones pack adds, and
     every mod in it. -->

**Join at** `mc.hu-tao.dev` (also `minecraft.hu-tao.dev` or the bare IP)
**Pack** [gemstones-26.1.2.mrpack](https://pages.hu-tao.dev/hutao/vps/mc1/gemstones-26.1.2.mrpack)
**With options** [gemstones-26.1.2-with-options.mrpack](https://pages.hu-tao.dev/hutao/vps/mc1/gemstones-26.1.2-with-options.mrpack)
**Minecraft** 26.1.2

The main survival world, on hard. Gameplay stays close to vanilla: the server
adds a few conveniences, and the pack is mostly about the game running and
looking better on your machine.

## What changes for everyone

- **Trees fall** ([FallingTree](https://modrinth.com/mod/fallingtree)): cut one
  log and the whole tree comes down.
- **Half the players can skip the night**
  ([Server Sleep](https://modrinth.com/mod/serversleep)): once 50% are in bed,
  morning comes.
- **Sound bounces and muffles**
  ([Sound Physics Remastered](https://modrinth.com/mod/sound-physics-remastered)):
  caves echo, walls muffle, and you can hear where things are. It needs the
  mod on your side too to be heard, which the pack has.
- **Distant terrain** ([Voxy](https://modrinth.com/mod/voxy) with its server
  side): the server sends far-away land as low-detail chunks, so you see well
  past your render distance.
- **Chat stays unreportable**
  ([No Chat Reports](https://modrinth.com/mod/no-chat-reports)).
- Under the hood: Lithium, FerriteCore and Krypton make the server itself
  faster, and a Discord integration mod connects it to Discord.

## What your pack adds

- **Performance**: Sodium (with Sodium Extra and its options screen), Iris for
  shaders, ImmediatelyFast, Entity Culling, More Culling, ModernFix,
  BadOptimizations, Better Block Entities and Dynamic FPS, which throttles the
  game while it is in the background.
- **Interface**:
  - [VoxelMap](https://modrinth.com/mod/voxelmap-updated): minimap and world
    map, with waypoints.
  - [Jade](https://modrinth.com/mod/jade): what you are looking at, and its
    state.
  - [AppleSkin](https://modrinth.com/mod/appleskin): food and saturation on the
    hunger bar.
  - [Shulker Box Tooltip](https://modrinth.com/mod/shulkerboxtooltip): hover a
    shulker box to see inside.
  - [Mouse Tweaks](https://modrinth.com/mod/mouse-tweaks): drag and scroll to
    move items.
  - [Controlling](https://modrinth.com/mod/controlling): a search box in the
    key bindings.
  - [Zoomify](https://modrinth.com/mod/zoomify): a zoom key.
  - [uku's Armor HUD](https://modrinth.com/mod/ukus-armor-hud): your armor and
    its durability, next to the hotbar.
  - More Chat History, Better Mount HUD, Borderless Mining (borderless
    fullscreen), Mod Menu.
- **Visuals**: LambDynamicLights (a torch in your hand lights the area),
  3D Skin Layers, BetterGrassify, Continuity (connected textures), Sodium
  Shadowy Path Blocks, and support for resource packs that use OptiFine
  features (Entity Model/Texture Features, OptiGUI, Skyboxify, Puzzle).

No shader packs are included; Iris is there if you want to add your own.

## Tips

- Every key is in _Options_ → _Controls_; Controlling's search finds them.
- Sodium's video settings replace vanilla's, with far more options. If the game
  stutters, lower _Render Distance_ there; Voxy's distant terrain is separate.

## Every mod

{{#include mc1-mods.md}}
