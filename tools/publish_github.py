"""Publish the validated ZIP as a GitHub Release using the job's GITHUB_TOKEN.

Adapted from XPIsland's scripts/publish_github.py (BSD-3-Clause, Matt Silverlock).
Reruns finish an existing release but never replace a ZIP with different bytes.
"""
import hashlib
import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True).strip()


def main():
    data = json.loads((ROOT / "dist/release.json").read_text())
    tag, archive = data["tag"], ROOT / "dist" / data["archive"]
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != (ROOT / "dist/SHA256SUMS").read_text().split()[0]:
        raise ValueError("ZIP does not match the validated build")
    releases = json.loads(gh("api", "--paginate", "--slurp", "repos/{owner}/{repo}/releases"))
    existing = next((r for page in releases for r in page if r["tag_name"] == tag), None)
    if existing:
        names = {a["name"] for a in existing["assets"]}
        if data["archive"] in names:
            with tempfile.TemporaryDirectory() as directory:
                gh("release", "download", tag, "--pattern", data["archive"], "--dir", directory)
                if hashlib.sha256((pathlib.Path(directory) / data["archive"]).read_bytes()).hexdigest() != digest:
                    raise ValueError("Existing release has a different ZIP; publish a new version instead")
        else:
            gh("release", "upload", tag, str(archive))
        if "SHA256SUMS" not in names:
            gh("release", "upload", tag, str(ROOT / "dist/SHA256SUMS"))
    else:
        args = ["release", "create", tag, str(archive), str(ROOT / "dist/SHA256SUMS"), "--verify-tag", "--draft",
                "--title", f"Auction House Profits {tag}", "--notes-file", str(ROOT / "dist/notes.md")]
        if data["prerelease"]:
            args.append("--prerelease")
        gh(*args)
    gh("release", "edit", tag, "--draft=false", "--prerelease=" + str(data["prerelease"]).lower())
    print(gh("release", "view", tag, "--json", "url", "--jq", ".url"))


if __name__ == "__main__":
    main()
