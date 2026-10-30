"""Lay option overrides over a pack's client files, for its -with-options build.

    options.py <out> <prefix> <options dir>...

<out> holds the pack's client files already. Each <options dir> mirrors the
game folder and is applied in order, so a later one wins:

- options.txt merges key by key into <out>/<prefix>options.txt, which starts
  from the pack's own if it ships one. Lines without a ':' (comments, blanks)
  are dropped, so the source files can be commented.
- every other file replaces <out>/<prefix><path> whole. Mod configs change
  shape between versions; replacing a file is predictable where a key merge
  of JSON, TOML and .properties is not.

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


def main(out: Path, prefix: str, sources: list[Path]) -> None:
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
        main(t / "out", "config/yosbr/", [t / "all", t / "mc9"])
        got = read(t / "out/config/yosbr/options.txt")
        assert got == {"fov": "0.5", "maxFps": "120", "key_a": "key.keyboard.c"}, got
        assert (t / "out/config/yosbr/config/x.json").exists()
        assert not (t / "out/options.txt").exists()
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--demo"]:
        demo()
    else:
        main(Path(sys.argv[1]), sys.argv[2], [Path(p) for p in sys.argv[3:]])
