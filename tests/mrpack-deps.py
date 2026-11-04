"""Check every hard `depends` in a world's pack against what each side gets.

usage: mrpack-deps.py <jars.json> <minecraft version> <fabric loader version>

jars.json is [{path, side, src}], side being both/client/server. See the
`check` in packs/mrpack.nix for why this exists.
"""
import io
import json
import re
import sys
import zipfile

jars_file, minecraft, fabricloader = sys.argv[1:4]
jars = json.load(open(jars_file))

# Provided by the platform, not by any mod jar. Fabric Loader ships
# MixinExtras inside its own jar (0.5.5 in loader 0.20.1).
BUILTIN = {"minecraft", "java", "fabricloader", "fabric-loader", "mixinextras"}


def semver(v):
    """(core, pre) for Fabric's semver, or None. pre is () for "1.0-", the
    lowest of all, and None for a release, the highest."""
    m = re.fullmatch(r"(\d+(?:\.\d+)*)(?:-([^+]*))?(?:\+.*)?", v.strip())
    if not m:
        return None
    pre = m[2]
    if pre is not None:
        pre = tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split(".") if p)
    return tuple(int(c) for c in m[1].split(".")), pre


def cmp(a, b):
    n = max(len(a[0]), len(b[0]))
    ca, cb = (c[0] + (0,) * (n - len(c[0])) for c in (a, b))
    if ca != cb:
        return -1 if ca < cb else 1
    pa, pb = ((1,) if p is None else (0, p) for p in (a[1], b[1]))
    return (pa > pb) - (pa < pb)


def term(t, v):
    """One Fabric version predicate term: *, =, >=, <=, >, <, ~, ^ or x-range."""
    if t in ("*", ""):
        return True
    op, ver = re.fullmatch(r"(>=|<=|>|<|=|~|\^)?(.*)", t).groups()
    if re.search(r"(^|\.)[xX*](\.|$)", ver):
        # 1.2.x: >=1.2.0- and below 1.3.0-
        core = ver.split(".")
        i = next(i for i, c in enumerate(core) if c in "xX*")
        if i == 0:
            return True
        lo = tuple(int(c) for c in core[:i])
        hi = lo[:-1] + (lo[-1] + 1,)
        return cmp(v, (lo, ())) >= 0 and cmp(v, (hi, ())) < 0
    b = semver(ver)
    if b is None:
        return None
    c = cmp(v, b)
    if op in (None, "="):
        return c == 0
    if op in ("~", "^"):
        hi = (b[0][0] + 1,) if op == "^" else (b[0][0], (b[0] + (0,))[1] + 1)
        return c >= 0 and cmp(v, (hi, ())) < 0
    return {">=": c >= 0, "<=": c <= 0, ">": c > 0, "<": c < 0}[op]


def satisfies(version, rng):
    """Fabric `depends` value: a string of AND-ed terms, or a list of them
    (any one will do). None when either side is not semver, so unjudged."""
    v = semver(version)
    if v is None:
        return None
    results = []
    for alt in [rng] if isinstance(rng, str) else rng:
        r = [term(t, v) for t in alt.split()] or [True]
        if None in r:
            return None
        results.append(all(r))
    return any(results)


# Voxy 0.2.18's range for Sodium, which mc1 shipped against 0.9.2.
assert satisfies("0.9.1+mc26.1.2", [">=0.9.1- <=0.9.1"])
assert not satisfies("0.9.2+mc26.1.2", [">=0.9.1- <=0.9.1"])
assert satisfies("0.9.1-beta.4", ">=0.9.1-") and not satisfies("0.9.1-beta.4", ">=0.9.1")
assert satisfies("1.21.1", "~1.21") and not satisfies("1.22", "~1.21")
assert satisfies("1.21.4", "1.21.x") and satisfies("1.9", "^1.0") and not satisfies("2.0", "^1.0")
assert satisfies("0.19.5", ">=0.18.6") and satisfies("x", "*") is None


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
    provided = {b: None for b in BUILTIN}
    provided.update({"minecraft": minecraft, "fabricloader": fabricloader})
    for _, _, jsons in present:
        # The outer jar's version wins: Sodium nests a jar that also says
        # "sodium", at 0.0.0, which would satisfy almost any range.
        for n, mj in enumerate(jsons):
            for i in [mj["id"], *mj.get("provides", [])]:
                if n == 0 or i not in provided:
                    provided[i] = str(mj.get("version", ""))
    for path, _, jsons in present:
        # Only the outer jar's depends: a nested jar's are its parent's business,
        # and the parent ships what they need.
        for dep, rng in ((jsons[0] if jsons else {}).get("depends") or {}).items():
            if dep not in provided:
                missing.append(f"{side}: {path} needs {dep} {rng}")
            elif provided[dep] is not None and satisfies(provided[dep], rng) is False:
                missing.append(f"{side}: {path} needs {dep} {rng}, pack has {provided[dep]}")
    print(f"pack: {side} gets {len(present)} mods")

# Version ranges are evaluated too. They used not to be, on the theory that a
# mismatch names itself in the server log, but a client-only mod never reaches
# a server: mc1 shipped Voxy 0.2.18 (Sodium 0.9.1 only) next to Sodium 0.9.2
# and every player's launch refused. A version that is not semver (a raw
# ${version}, a date) is not judged, as Fabric's own string compare would be
# guesswork here.
if missing:
    print("pack: unmet hard dependencies", file=sys.stderr)
    for m in missing:
        print("  " + m, file=sys.stderr)
    sys.exit(1)
print(f"pack: every hard dependency is met (MC {minecraft}, fabric {fabricloader})")
