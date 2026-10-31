"""Check a built options.txt will load, instead of being thrown away whole.

usage: options-txt.py <options.txt> <data version>

Minecraft does not skip a bad line in options.txt: one exception while loading
discards the WHOLE file and the game writes its defaults over it. Without a
`version:` it takes the file for a pre-1.13 one, and the 1.13 key fixer throws
on `key.keyboard.b`. Lost every option on mc4 on 2026-10-31. So:

- every line is key:value, each key once
- version: is there and is the game's data version
- every key_* is bound to a key.keyboard.* or key.mouse.* name
"""

import re
import sys

KEY = re.compile(r"key\.(keyboard|mouse)\.[a-z0-9._-]+")


def problems(text: str, data_version: str) -> list[str]:
    out, seen = [], {}
    for n, line in enumerate(text.splitlines(), 1):
        if ":" not in line:
            out.append(f"line {n}: not key:value: {line!r}")
            continue
        k, v = line.split(":", 1)
        if k in seen:
            out.append(f"line {n}: {k} again (first on line {seen[k]})")
        seen[k] = n
        if k.startswith("key_") and not KEY.fullmatch(v):
            out.append(f"line {n}: {k} is bound to {v!r}, not a key.keyboard.* or key.mouse.* name")
    version = re.search(r"^version:(.*)$", text, re.M)
    if not version:
        out.append(f"no version: line; Minecraft would run every fixer since 1.13 on it (want version:{data_version})")
    elif version[1] != data_version:
        out.append(f"version:{version[1]}, but this Minecraft's data version is {data_version}")
    return out


def demo() -> None:
    good = "version:5023\nfov:1.0\nkey_key.jump:key.keyboard.space\nkey_key.attack:key.mouse.left\n"
    assert problems(good, "5023") == [], problems(good, "5023")
    assert len(problems("fov:1.0\nkey_key.jump:key.keyboard.b\n", "5023")) == 1  # no version
    assert len(problems(good, "4790")) == 1  # wrong version
    assert len(problems(good + "key_key.use:57\n", "5023")) == 1  # LWJGL2 keycode
    assert len(problems(good + "fov:0.5\n", "5023")) == 1  # duplicate
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--demo"]:
        demo()
        sys.exit()
    path, data_version = sys.argv[1:]
    found = problems(open(path, encoding="utf-8").read(), data_version)
    for p in found:
        print(f"{path}: {p}", file=sys.stderr)
    if found:
        print("Minecraft would discard this whole options.txt for its defaults.", file=sys.stderr)
        sys.exit(1)
