"""Check every hard `depends` in a world's pack against what each side gets.

usage: mrpack-deps.py <jars.json> <minecraft version> <fabric loader version>

jars.json is [{path, side, src}], side being both/client/server. See the
`check` in packs/mrpack.nix for why this exists.
"""
import io
import json
import sys
import zipfile

jars_file, minecraft, fabricloader = sys.argv[1:4]
jars = json.load(open(jars_file))

# Provided by the platform, not by any mod jar.
BUILTIN = {"minecraft", "java", "fabricloader", "fabric-loader"}


def mod_jsons(data):
    """fabric.mod.json of a jar and of every jar nested in it (jar-in-jar)."""
    z = zipfile.ZipFile(io.BytesIO(data))
    names = set(z.namelist())
    if "fabric.mod.json" in names:
        # strict=False: some mods ship raw newlines inside JSON strings.
        yield json.loads(z.read("fabric.mod.json").decode("utf-8", "replace"), strict=False)
    for n in names:
        if n.startswith("META-INF/jars/") and n.endswith(".jar"):
            yield from mod_jsons(z.read(n))


mods = []
for j in jars:
    with open(j["src"], "rb") as f:
        mods.append((j["path"], j["side"], list(mod_jsons(f.read()))))

missing = []
for side in ("server", "client"):
    present = [m for m in mods if m[1] in ("both", side)]
    provided = set(BUILTIN)
    for _, _, jsons in present:
        for mj in jsons:
            provided.add(mj["id"])
            provided.update(mj.get("provides", []))
    for path, _, jsons in present:
        # Only the outer jar's depends: a nested jar's are its parent's business,
        # and the parent ships what they need.
        for dep, rng in ((jsons[0] if jsons else {}).get("depends") or {}).items():
            if dep not in provided:
                missing.append(f"{side}: {path} needs {dep} {rng}")
    print(f"pack: {side} gets {len(present)} mods")

# Version RANGES are not evaluated: Fabric's semver grammar is not worth a
# second implementation, and a range mismatch names itself in the server log.
# A missing mod does not, on the client: it is a crash on every player's launch.
if missing:
    print("pack: unmet hard dependencies", file=sys.stderr)
    for m in missing:
        print("  " + m, file=sys.stderr)
    sys.exit(1)
print(f"pack: every hard dependency is met (MC {minecraft}, fabric {fabricloader})")
