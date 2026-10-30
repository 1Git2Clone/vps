"""Select options packs affected by a Git diff.

Usage: python3 -I packs/changed_worlds.py BASE HEAD [--pull-request]

Changes under packs/mcN/ select that world. Shared pack code, any option
overrides, flake inputs, dependency checks, or an options-pack workflow select
all worlds. Other paths select none. Pull requests compare from the merge base;
pushes compare the exact before/after trees. An empty, zero, or unavailable
base selects every world, so manual runs and new branches get full coverage.
The result is a space-separated list suitable for a workflow output.
"""

from argparse import ArgumentParser
from pathlib import PurePosixPath
from subprocess import CalledProcessError, check_output
from sys import stderr

WORLDS = ("mc1", "mc2", "mc3", "mc4")
SHARED_FILES = {
    "flake.nix",
    "flake.lock",
    ".forgejo/workflows/option-packs.yml",
    ".github/workflows/option-packs.yml",
}


def affected_worlds(paths: list[str]) -> tuple[str, ...]:
    selected: set[str] = set()
    for path in paths:
        parts = PurePosixPath(path).parts
        if parts[:1] == ("packs",):
            if len(parts) > 2 and parts[1] in WORLDS:
                selected.add(parts[1])
            else:
                return WORLDS
        elif (
            parts[:1] == ("options",)
            or path in SHARED_FILES
            or (path.startswith("tests/mrpack-") and path.endswith(".py"))
        ):
            return WORLDS
    return tuple(world for world in WORLDS if world in selected)


def changed_worlds(base: str, head: str, pull_request: bool) -> tuple[str, ...]:
    if not base or set(base) == {"0"}:
        return WORLDS
    comparison = f"{base}...{head}" if pull_request else f"{base}..{head}"
    try:
        # Disable rename detection so both the removed and added paths count.
        output = check_output(
            ["git", "diff", "--name-only", "--no-renames", "-z", comparison, "--"]
        )
    except CalledProcessError:
        print("Cannot compare revisions; selecting all worlds", file=stderr)
        return WORLDS
    paths = output.decode("utf-8", errors="surrogateescape").split("\0")[:-1]
    return affected_worlds(paths)


def main() -> None:
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("base", help="before/base commit; empty means all worlds")
    parser.add_argument("head", help="after/head commit")
    parser.add_argument(
        "--pull-request", action="store_true", help="compare from the merge base"
    )
    arguments = parser.parse_args()
    print(" ".join(changed_worlds(arguments.base, arguments.head, arguments.pull_request)))


if __name__ == "__main__":
    main()
