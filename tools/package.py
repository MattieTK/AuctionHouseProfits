#!/usr/bin/env python3
"""Build a release zip of the addon folder.

Checks the version is consistent, the vendored SomethingNeedDoing files match
their pinned hashes, then writes dist/AuctionHouseProfits-<version>.zip with
fixed timestamps so the same source always produces the same bytes.

Usage (from addon/):  python3 tools/package.py
"""
import hashlib
import json
import pathlib
import re
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON = "AuctionHouseProfits"
SRC = ROOT / ADDON
DIST = ROOT / "dist"
IGNORED = {".DS_Store", "Thumbs.db"}


def fail(message):
    print("package: " + message, file=sys.stderr)
    sys.exit(1)


def toc_field(name):
    text = (SRC / f"{ADDON}.toc").read_text()
    match = re.search(rf"^## {name}: *(.+)$", text, re.M)
    return match.group(1).strip() if match else None


def main():
    version = toc_field("Version")
    interface = toc_field("Interface")
    core = (SRC / "Core.lua").read_text()
    core_version = re.search(r'local VERSION = "([^"]+)"', core)
    if not version or not core_version or core_version.group(1) != version:
        fail(f"TOC version {version!r} doesn't match Core.lua {core_version and core_version.group(1)!r}")
    if interface != "16001":
        fail(f"expected WoW Forever interface 16001, got {interface!r}")

    # Every file the TOC loads must exist.
    for line in (SRC / f"{ADDON}.toc").read_text().splitlines():
        if line and not line.startswith("#") and not (SRC / line.replace("\\", "/")).is_file():
            fail(f"TOC lists missing file {line}")

    # Vendored framework must be byte-identical to the pinned upstream release.
    snd = SRC / "Libs" / "SomethingNeedDoing"
    pin = json.loads((snd / "UPSTREAM.json").read_text())
    for name, digest in pin["sha256"].items():
        actual = hashlib.sha256((snd / name).read_bytes()).hexdigest()
        if actual != digest:
            fail(f"SomethingNeedDoing/{name} differs from pinned {pin['tag']}")

    files = sorted(p for p in SRC.rglob("*") if p.is_file() and p.name not in IGNORED)
    DIST.mkdir(exist_ok=True)
    out = DIST / f"{ADDON}-{version}.zip"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for path in files:
            arc = f"{ADDON}/{path.relative_to(SRC).as_posix()}"
            info = zipfile.ZipInfo(arc, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, path.read_bytes())
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    (DIST / "SHA256SUMS").write_text(f"{digest}  {out.name}\n")
    print(f"built {out.relative_to(ROOT)} ({len(files)} files)\nsha256 {digest}")


if __name__ == "__main__":
    main()
