"""Check that options.txt only enables resource packs the pack really ships.

usage: mrpack-options.py <entries.json> <options.txt> [<resourcepacks dir>]

entries.json is [{path, src}] for every file in the pack. Minecraft drops an
entry it cannot find without a word, so a mod update that renames a zip (as
Fresh Animations 1.10.5 -> 1.11.1 did) silently turns that pack off for every
player. A pack made for another version is dropped too unless it is also in
incompatibleResourcePacks. A folder pack in the pack's own resourcepacks/
ships as a client override, so it counts too.
"""
import io
import json
import os
import re
import sys
import zipfile

entries_file, options_file, *packs_dir = sys.argv[1:]
entries = json.load(open(entries_file))
options = open(options_file, encoding="utf-8").read()


def option(key):
    m = re.search(rf"^{key}:(.*)$", options, re.M)
    return json.loads(m.group(1)) if m else []


files = {e["path"].removeprefix("resourcepacks/") for e in entries if e["path"].startswith("resourcepacks/")}
for d in packs_dir:
    files.update(n for n in os.listdir(d) if os.path.isdir(os.path.join(d, n)))


def builtin_packs(data):
    """<mod id>:<folder> for every resourcepacks/<folder> a jar ships."""
    z = zipfile.ZipFile(io.BytesIO(data))
    names = set(z.namelist())
    if "fabric.mod.json" in names:
        mod_id = json.loads(z.read("fabric.mod.json").decode("utf-8", "replace"), strict=False)["id"]
        for n in names:
            m = re.fullmatch(r"resourcepacks/([^/]+)/pack\.mcmeta", n)
            if m:
                yield f"{mod_id}:{m.group(1)}"
    for n in names:
        if n.startswith("META-INF/jars/") and n.endswith(".jar"):
            yield from builtin_packs(z.read(n))


builtins = {"vanilla"}
for e in entries:
    if e["path"].startswith("mods/"):
        with open(e["src"], "rb") as f:
            builtins.update(builtin_packs(f.read()))

enabled = option("resourcePacks")
bad = []
for p in enabled:
    if p.startswith("file/"):
        if p.removeprefix("file/") not in files:
            bad.append(f"resourcePacks: {p} is not a file in resourcepacks/")
    elif p not in builtins:
        bad.append(f"resourcePacks: {p} is not a built-in pack of any mod in the pack")
for p in option("incompatibleResourcePacks"):
    if p not in enabled:
        bad.append(f"incompatibleResourcePacks: {p} is not in resourcePacks")

for b in bad:
    print(b)
if bad:
    sys.exit(1)
print(f"options: all {len(enabled)} enabled resource packs exist")
