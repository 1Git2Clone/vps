"""Lay option overrides over a pack's client files, for its -with-options build.

    options.py <out> <prefix> <data version> <options dir>...

<out> holds the pack's client files already. Each <options dir> mirrors the
game folder and is applied in order, so a later one wins:

- options.txt merges key by key into <out>/<prefix>options.txt, which starts
  from the pack's own if it ships one. Lines without a ':' (comments, blanks)
  are dropped, so the source files can be commented.
- every other file replaces <out>/<prefix><path> whole. Mod configs change
  shape between versions; replacing a file is predictable where a key merge
  of JSON, TOML and .properties is not.

<data version> is the game's (version.json's world_version), written as
options.txt's `version:`. Without it Minecraft takes the file for a pre-1.13
one and runs every options fixer on it; the 1.13 key fixer throws on
`key.keyboard.b`, and the game then discards the WHOLE file for its defaults.
Lost every option on mc4 on 2026-10-31.

<prefix> is "config/yosbr/" for a shared pack, so the options are only where
a player starts (see packs/mrpack.nix), and "" for a pack whose own options
are plain overrides.
"""

import shutil
import sys
from pathlib import Path


def read(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    pairs = (line.split(":", 1) for line in path.read_text().splitlines() if ":" in line)
    return {k: v for k, v in pairs if not k.lstrip().startswith("#")}


def main(out: Path, prefix: str, data_version: str, sources: list[Path]) -> None:
    target = out / prefix / "options.txt"
    options = read(target)
    for src in sources:
        for f in sorted(p for p in src.rglob("*") if p.is_file()):
            rel = f.relative_to(src)
            if rel == Path("options.txt"):
                options |= read(f)
            else:
                dst = out / prefix / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(f, dst)
    if options:
        options.pop("version", None)
        options = {"version": data_version} | options
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("".join(f"{k}:{v}\n" for k, v in options.items()))


def demo() -> None:
    import tempfile

    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / "out/config/yosbr").mkdir(parents=True)
        (t / "out/config/yosbr/options.txt").write_text("fov:0.0\nmaxFps:120\n")
        (t / "all/config").mkdir(parents=True)
        (t / "all/options.txt").write_text("# comment\nfov:1.0\nkey_a:key.keyboard.c\n")
        (t / "all/config/x.json").write_text("{}")
        (t / "mc9").mkdir()
        (t / "mc9/options.txt").write_text("fov:0.5\n")
        main(t / "out", "config/yosbr/", "5023", [t / "all", t / "mc9"])
        text = (t / "out/config/yosbr/options.txt").read_text()
        assert text.startswith("version:5023\n"), text
        got = read(t / "out/config/yosbr/options.txt")
        assert got == {"version": "5023", "fov": "0.5", "maxFps": "120", "key_a": "key.keyboard.c"}, got
        assert (t / "out/config/yosbr/config/x.json").exists()
        assert not (t / "out/options.txt").exists()
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--demo"]:
        demo()
    else:
        main(Path(sys.argv[1]), sys.argv[2], sys.argv[3], [Path(p) for p in sys.argv[4:]])
