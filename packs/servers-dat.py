"""Write a servers.dat holding one server, for a pack's -with-options build.

    servers-dat.py <out file> <name> <address>

servers.dat is the multiplayer list: uncompressed NBT, a root compound with a
`servers` list of {name, ip} compounds. One entry, so a world's pack lists
that world and no other.

ponytail: NBT written by hand, fine for one fixed-shape file; switch to
python3Packages.nbtlib if this ever reads or edits real NBT (level.dat, ...).
"""

import struct
import sys
from pathlib import Path


def string(s: str) -> bytes:
    b = s.encode()
    return struct.pack(">H", len(b)) + b


def servers_dat(name: str, ip: str) -> bytes:
    entry = b"\x08" + string("name") + string(name) + b"\x08" + string("ip") + string(ip) + b"\x00"
    servers = b"\x09" + string("servers") + b"\x0a" + struct.pack(">i", 1) + entry
    return b"\x0a" + string("") + servers + b"\x00"


def demo() -> None:
    got = servers_dat("a", "b")
    want = bytes.fromhex(
        "0a0000"  # root compound, empty name
        "090007" + b"servers".hex() + "0a00000001"  # list of 1 compound
        "080004" + b"name".hex() + "000161"  # name: "a"
        "080002" + b"ip".hex() + "000162"  # ip: "b"
        "00"  # end of entry
        "00"  # end of root
    )
    assert got == want, got.hex()
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--demo"]:
        demo()
    else:
        out = Path(sys.argv[1])
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(servers_dat(sys.argv[2], sys.argv[3]))
