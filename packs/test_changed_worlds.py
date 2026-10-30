"""Check world selection, including push and pull-request Git comparisons."""

from pathlib import Path
from subprocess import PIPE, check_output
from sys import executable
from tempfile import TemporaryDirectory
from unittest import TestCase, main

from changed_worlds import WORLDS, affected_worlds

SCRIPT = Path(__file__).with_name("changed_worlds.py").resolve()


class AffectedWorldsTests(TestCase):
    def test_individual_and_multiple_worlds(self) -> None:
        self.assertEqual(affected_worlds(["packs/mc2/mods/a.pw.toml"]), ("mc2",))
        self.assertEqual(
            affected_worlds(["packs/mc4/pack.toml", "packs/mc1/index.toml"]),
            ("mc1", "mc4"),
        )

    def test_shared_inputs_select_every_world(self) -> None:
        for path in (
            "packs/default.nix",
            "packs/startup.py",
            "packs/options/all/options.txt",
            "packs/options/mc2/options.txt",
            "options/options.txt",
            "flake.nix",
            "flake.lock",
            "tests/mrpack-deps.py",
            ".forgejo/workflows/option-packs.yml",
            ".github/workflows/option-packs.yml",
        ):
            with self.subTest(path=path):
                self.assertEqual(affected_worlds(["packs/mc1/index.toml", path]), WORLDS)

    def test_unrelated_changes_select_none(self) -> None:
        self.assertEqual(affected_worlds(["README.md", "modules/firewall.nix"]), ())
        self.assertEqual(affected_worlds([]), ())


class GitComparisonTests(TestCase):
    def setUp(self) -> None:
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.git("init", "-q", "-b", "main")
        self.commit_file("README.md")

    def git(self, *arguments: str) -> str:
        return check_output(
            [
                "git", "-c", "user.name=Test", "-c",
                "user.email=test@example.invalid", *arguments,
            ],
            cwd=self.root,
            text=True,
        ).strip()

    def commit_file(self, name: str) -> str:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("test\n", encoding="utf-8")
        self.git("add", name)
        self.git("commit", "-qm", name)
        return self.git("rev-parse", "HEAD")

    def select(self, base: str, head: str, *options: str) -> tuple[str, ...]:
        output = check_output(
            [executable, "-I", str(SCRIPT), base, head, *options],
            cwd=self.root,
            stderr=PIPE,
            text=True,
        )
        return tuple(output.split())

    def test_push_includes_every_commit(self) -> None:
        base = self.git("rev-parse", "HEAD")
        self.commit_file("packs/mc1/mods/one.pw.toml")
        head = self.commit_file("packs/mc3/mods/three.pw.toml")
        self.assertEqual(self.select(base, head), ("mc1", "mc3"))

    def test_pull_request_excludes_target_branch_changes(self) -> None:
        self.git("checkout", "-qb", "feature")
        head = self.commit_file("packs/mc2/mods/two.pw.toml")
        self.git("checkout", "-q", "main")
        base = self.commit_file("packs/mc3/mods/three.pw.toml")
        self.assertEqual(self.select(base, head, "--pull-request"), ("mc2",))

    def test_rename_selects_source_and_destination_worlds(self) -> None:
        base = self.commit_file("packs/mc1/mods/mod.pw.toml")
        destination = self.root / "packs/mc4/mods"
        destination.mkdir(parents=True)
        self.git("mv", "packs/mc1/mods/mod.pw.toml", "packs/mc4/mods/mod.pw.toml")
        self.git("commit", "-qm", "move mod")
        self.assertEqual(self.select(base, "HEAD"), ("mc1", "mc4"))

    def test_deleted_mod_still_selects_its_world(self) -> None:
        base = self.commit_file("packs/mc2/mods/mod.pw.toml")
        self.git("rm", "packs/mc2/mods/mod.pw.toml")
        self.git("commit", "-qm", "remove mod")
        self.assertEqual(self.select(base, "HEAD"), ("mc2",))

    def test_manual_new_branch_and_missing_base_select_all(self) -> None:
        for base in ("", "0" * 40, "unavailable-commit"):
            with self.subTest(base=base):
                self.assertEqual(self.select(base, "HEAD"), WORLDS)


if __name__ == "__main__":
    main()
