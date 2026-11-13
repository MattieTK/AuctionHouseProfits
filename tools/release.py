"""Validate a release tag and write dist/release.json. No network writes.

Adapted from XPIsland's scripts/release.py (BSD-3-Clause, Matt Silverlock).
Usage: RELEASE_TAG=v0.1.0 python3 tools/release.py   (or pass the tag as argv[1])
"""
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
ADDON = "AuctionHouseProfits"
VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(alpha|beta|rc)\.([1-9][0-9]*))?"
# CurseForge game version for WoW Forever, as used by XPIsland and BigWigs packager >= 2.6.0.
GAME_VERSION, GAME_VERSION_TYPE = "1.60.1", 88568


def metadata(tag, toc):
    match = re.fullmatch("v" + VERSION, tag)
    if not match:
        raise ValueError("Use vX.Y.Z, vX.Y.Z-alpha.N, vX.Y.Z-beta.N or vX.Y.Z-rc.N")
    version = re.search(r"^## Version: (.+)$", toc, re.M)
    if not version or version[1].strip() != tag[1:]:
        raise ValueError("Tag must exactly match the TOC version")
    if re.findall(r"^## Interface[^:]*: (.+)$", toc, re.M) != ["16001"]:
        raise ValueError("This release supports only WoW Forever (16001)")
    project = re.search(r"^## X-Curse-Project-ID: *(\d+)$", toc, re.M)
    kind = "alpha" if match[4] == "alpha" else "beta" if match[4] else "release"
    return dict(tag=tag, version=tag[1:], release_type=kind, prerelease=kind != "release",
                archive=f"{ADDON}-{tag[1:]}.zip", project_id=int(project[1]) if project else None,
                game_version=GAME_VERSION, game_version_type=GAME_VERSION_TYPE)


def notes(version):
    """The CHANGELOG.md section for this version."""
    text = (ROOT / "CHANGELOG.md").read_text()
    match = re.search(rf"^## {re.escape(version)}\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not match or not match[1].strip():
        raise ValueError(f"Add a '## {version}' section to CHANGELOG.md before tagging")
    return match[1].strip() + "\n"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def check_tag(tag):
    ref = f"refs/tags/{tag}"
    if git("cat-file", "-t", ref) != "tag":
        raise ValueError("Release tags must be annotated: git tag -a vX.Y.Z -m ...")
    commit = git("rev-parse", f"{ref}^{{commit}}")
    if git("rev-parse", "HEAD") != commit:
        raise ValueError("Checkout must be the tagged commit")
    if subprocess.run(["git", "merge-base", "--is-ancestor", commit, "origin/main"], cwd=ROOT).returncode:
        raise ValueError("Tagged commit is not on origin/main")
    return commit


def main():
    tag = os.environ.get("RELEASE_TAG") or sys.argv[1]
    data = metadata(tag, (ROOT / ADDON / f"{ADDON}.toc").read_text())
    core = re.search(r'local VERSION = "([^"]+)"', (ROOT / ADDON / "Core.lua").read_text())
    if not core or core[1] != data["version"]:
        raise ValueError("Core.lua VERSION must match the tag")
    data["commit"] = check_tag(tag)
    (ROOT / "dist").mkdir(exist_ok=True)
    (ROOT / "dist/notes.md").write_text(notes(data["version"]))
    (ROOT / "dist/release.json").write_text(json.dumps(data, indent=2) + "\n")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as out:
            out.write(f"commit={data['commit']}\n")
    print(f"Validated {tag}: {data['release_type']}, WoW Forever {GAME_VERSION}, commit {data['commit']}")


if __name__ == "__main__":
    main()
