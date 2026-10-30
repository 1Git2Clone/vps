#!/usr/bin/env python3
"""Smoke-test a built modpack by starting its Fabric dedicated server.

Usage: ``python3 -I packs/startup.py PACK.mrpack SERVER_MODS_DIR``.

PACK.mrpack is the pack build; SERVER_MODS_DIR is the matching
*-server-mods Nix output. The script copies in the server-required jars,
checks each jar against the SHA-512 recorded in the pack, installs the pack's
Minecraft and Fabric Loader versions, and starts the server in a temporary
directory with a small flat world. It succeeds when the server logs Done
within five minutes, and exits nonzero on an install error, early server exit,
or timeout. The server is stopped and the temporary directory is removed on
exit.

The first run needs network access to download Fabric's installer and the
Minecraft server files. CI supplies Java 21 for Minecraft 1.21.x and Java 25
for Minecraft 26.x. This test does not start the itzg container or load a
world's live server data.
"""

from __future__ import annotations

from argparse import ArgumentParser
from collections import deque
from hashlib import file_digest
from json import loads
from os import environ
from pathlib import Path, PurePosixPath
from selectors import EVENT_READ, DefaultSelector
from shutil import copyfile, copyfileobj
from subprocess import PIPE, STDOUT, Popen, TimeoutExpired, run
from tempfile import TemporaryDirectory
from time import monotonic
from typing import Literal, TypedDict
from urllib.request import Request, urlopen
from zipfile import ZipFile


class PackFile(TypedDict):
    path: str
    hashes: dict[str, str]
    env: dict[str, Literal["required", "unsupported"]]


class PackIndex(TypedDict):
    dependencies: dict[str, str]
    files: list[PackFile]


INSTALLER_VERSION = "1.1.2"
STARTUP_TIMEOUT_SECONDS = 300
DOWNLOAD_TIMEOUT_SECONDS = 300
INSTALL_TIMEOUT_SECONDS = 300
JAVA_HEAP = "2G"


def download(url: str, destination: Path) -> None:
    request = Request(url, headers={"User-Agent": "vps-pack-startup-ci"})
    with urlopen(request, timeout=DOWNLOAD_TIMEOUT_SECONDS) as response:
        with destination.open("wb") as output:
            copyfileobj(response, output)


def read_pack_index(pack_path: Path) -> PackIndex:
    with ZipFile(pack_path) as archive:
        index: PackIndex = loads(archive.read("modrinth.index.json"))
    return index


def verify_server_mods(
    index: PackIndex, mods_source: Path, server_root: Path
) -> None:
    for entry in index["files"]:
        relative_path = PurePosixPath(entry["path"])
        if relative_path.parts[:1] != ("mods",) or entry["env"]["server"] != "required":
            continue

        source = mods_source.joinpath(*relative_path.parts)
        destination = server_root.joinpath(*relative_path.parts)
        if not source.is_file():
            raise FileNotFoundError(f"Nix server-mods output is missing {entry['path']}")

        destination.parent.mkdir(parents=True, exist_ok=True)
        copyfile(source, destination)
        if sha512(destination) != entry["hashes"]["sha512"]:
            raise ValueError(f"SHA-512 mismatch for {entry['path']}")


def sha512(path: Path) -> str:
    with path.open("rb") as file:
        return file_digest(file, "sha512").hexdigest()


def java_for(minecraft_version: str) -> str:
    variable = "MC_JAVA_21" if minecraft_version.startswith("1.") else "MC_JAVA_25"
    return environ.get(variable, "java")


def install_fabric_server(
    java: str, server_root: Path, minecraft_version: str, loader_version: str
) -> None:
    installer = server_root / "fabric-installer.jar"
    installer_url = (
        "https://maven.fabricmc.net/net/fabricmc/fabric-installer/"
        f"{INSTALLER_VERSION}/fabric-installer-{INSTALLER_VERSION}.jar"
    )
    download(installer_url, installer)
    run(
        [
            java,
            "-jar",
            str(installer),
            "server",
            "-dir",
            str(server_root),
            "-mcversion",
            minecraft_version,
            "-loader",
            loader_version,
            "-downloadMinecraft",
        ],
        check=True,
        timeout=INSTALL_TIMEOUT_SECONDS,
    )


def write_server_settings(server_root: Path) -> None:
    (server_root / "eula.txt").write_text("eula=true\n", encoding="utf-8")
    (server_root / "server.properties").write_text(
        "online-mode=false\n"
        "server-port=25565\n"
        "level-type=minecraft:flat\n"
        "generate-structures=false\n"
        "view-distance=2\n"
        "simulation-distance=2\n",
        encoding="utf-8",
    )


def wait_for_server(java: str, server_root: Path, pack_name: str) -> None:
    process = Popen(
        [java, "-Xms512M", f"-Xmx{JAVA_HEAP}", "-jar", "fabric-server-launch.jar", "nogui"],
        cwd=server_root,
        stdout=PIPE,
        stderr=STDOUT,
        text=True,
        bufsize=1,
    )
    if process.stdout is None:
        raise RuntimeError("failed to capture Minecraft server output")

    output_tail: deque[str] = deque(maxlen=100)
    deadline = monotonic() + STARTUP_TIMEOUT_SECONDS
    with DefaultSelector() as selector:
        selector.register(process.stdout, EVENT_READ)
        try:
            while monotonic() < deadline:
                events = selector.select(timeout=min(1, deadline - monotonic()))
                if not events:
                    if process.poll() is not None:
                        raise RuntimeError(
                            f"server exited before Done (exit {process.returncode})"
                        )
                    continue

                line = process.stdout.readline()
                if not line:
                    continue
                output_tail.append(line.rstrip())
                print(line, end="", flush=True)
                if "Done (" in line:
                    print(f"{pack_name}: server reached Done", flush=True)
                    return

            tail = "\n".join(output_tail)
            raise TimeoutError(
                f"server did not reach Done within {STARTUP_TIMEOUT_SECONDS} seconds\n{tail}"
            )
        finally:
            stop_server(process)


def stop_server(process: Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=15)
    except TimeoutExpired:
        process.kill()
        process.wait()


def boot_pack(pack_path: Path, mods_source: Path) -> None:
    index = read_pack_index(pack_path)
    minecraft_version = index["dependencies"]["minecraft"]
    loader_version = index["dependencies"]["fabric-loader"]
    java = java_for(minecraft_version)

    with TemporaryDirectory(prefix="mc-startup-") as temporary:
        server_root = Path(temporary)
        verify_server_mods(index, mods_source, server_root)
        install_fabric_server(java, server_root, minecraft_version, loader_version)
        write_server_settings(server_root)
        wait_for_server(java, server_root, pack_path.name)


def main() -> int:
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("pack", type=Path, help="built .mrpack file")
    parser.add_argument(
        "server_mods", type=Path, help="Nix server-mods output directory"
    )
    arguments = parser.parse_args()
    boot_pack(arguments.pack, arguments.server_mods)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
