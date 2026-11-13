"""Upload the validated ZIP to CurseForge for WoW Forever.

Adapted from XPIsland's scripts/publish_curseforge.py (BSD-3-Clause, Matt Silverlock).
Uses the documented Upload API with the exact Forever game version: no
version fallback, no repackaging, no token on the command line, no POST retries.
A pending marker on the GitHub Release stops a rerun from uploading twice.
"""
import hashlib
import json
import os
import pathlib
import subprocess
import urllib.error
import urllib.request
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = "https://wow.curseforge.com"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Unexpected CurseForge redirect; upload was not retried")


def request(path, token, body=None, content_type=None):
    headers = {"X-Api-Token": token, "Accept": "application/json", "User-Agent": "AuctionHouseProfits-release/1"}
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(BASE + path, data=body, headers=headers)
    try:
        with urllib.request.build_opener(NoRedirect()).open(req, timeout=90) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Never echo response bodies or headers.
        raise RuntimeError(f"CurseForge HTTP {error.code}; check the author dashboard before retrying") from None
    except (urllib.error.URLError, TimeoutError):
        raise RuntimeError("CurseForge request failed; check the author dashboard before retrying") from None


def exact_version(versions, data):
    matches = [v for v in versions if v["name"] == data["game_version"] and v["gameVersionTypeID"] == data["game_version_type"]]
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one WoW Forever {data['game_version']} version on CurseForge; refusing to guess")
    return matches[0]["id"]


def multipart(metadata, archive):
    boundary = "AuctionHouseProfits-" + uuid.uuid4().hex
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="metadata"\r\n'
            "Content-Type: application/json\r\n\r\n").encode() + json.dumps(metadata).encode()
    body += (f'\r\n--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{archive.name}"\r\n'
             "Content-Type: application/zip\r\n\r\n").encode() + archive.read_bytes()
    return body + f"\r\n--{boundary}--\r\n".encode(), f"multipart/form-data; boundary={boundary}"


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True).strip()


def summary(line):
    print(line)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as out:
            out.write(line + "\n")


def main():
    token = os.environ.get("CF_API_TOKEN")
    if not token:
        raise ValueError("CF_API_TOKEN is missing; no CurseForge upload attempted")
    data = json.loads((ROOT / "dist/release.json").read_text())
    if not data.get("project_id"):
        raise ValueError("Add '## X-Curse-Project-ID: <id>' to the TOC; no CurseForge upload attempted")
    tag = data["tag"]
    names = json.loads(gh("release", "view", tag, "--json", "assets", "--jq", "[.assets[].name]"))
    if "curseforge-receipt.json" in names:
        summary("CurseForge already has this release (receipt found); nothing uploaded.")
        return
    if "curseforge-upload-pending.json" in names:
        raise ValueError("An earlier upload may have reached CurseForge. Check the project's files, then remove "
                         "curseforge-upload-pending.json from the GitHub Release before retrying")
    archive = ROOT / "dist" / data["archive"]
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != (ROOT / "dist/SHA256SUMS").read_text().split()[0]:
        raise ValueError("ZIP does not match the validated build")
    version_id = exact_version(request("/api/game/wow/versions", token), data)
    metadata = dict(displayName=f"Auction House Profits {tag}", gameVersions=[version_id],
                    releaseType=data["release_type"], changelogType="markdown",
                    changelog=(ROOT / "dist/notes.md").read_text(), isMarkedForManualRelease=False)
    body, content_type = multipart(metadata, archive)
    pending = ROOT / "dist/curseforge-upload-pending.json"
    pending.write_text(json.dumps(dict(tag=tag, project_id=data["project_id"], sha256=digest)) + "\n")
    gh("release", "upload", tag, str(pending))
    response = request(f"/api/projects/{data['project_id']}/upload-file", token, body, content_type)
    file_id = response.get("id")
    if not isinstance(file_id, int) or file_id <= 0:
        raise ValueError("Upload response has no file ID; check CurseForge before retrying")
    receipt = ROOT / "dist/curseforge-receipt.json"
    receipt.write_text(json.dumps(dict(file_id=file_id, project_id=data["project_id"], tag=tag, sha256=digest,
                                       release_type=data["release_type"], game_version=data["game_version"]), indent=2) + "\n")
    gh("release", "upload", tag, str(receipt))
    gh("release", "delete-asset", tag, pending.name, "--yes")
    summary(f"CurseForge accepted file {file_id} ({data['release_type']}, WoW Forever {data['game_version']}). "
            "Moderation approval isn't reported by the upload API.")


if __name__ == "__main__":
    main()
