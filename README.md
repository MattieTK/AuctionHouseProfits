# Auction House Profits: WoW Forever add-on

Source for the `AuctionHouseProfits` add-on. The folder players install is
[`AuctionHouseProfits/`](AuctionHouseProfits/README.md), which also has the
player-facing description.

## Layout

| Path | What it is |
| --- | --- |
| `AuctionHouseProfits/` | The add-on, exactly as it ships. TOC load order is authoritative. |
| `AuctionHouseProfits/Libs/SomethingNeedDoing/` | Vendored framework, pinned by `UPSTREAM.json`. Don't edit; update from upstream. |
| `tests/model_test.lua` | Pure math tests. |
| `tests/runtime_test.lua` | Loads the whole add-on against a WoW mock and drives merchant, window, AH tab and price-check flows. |
| `tests/snd_wow.lua` | WoW boundary mock from SomethingNeedDoing v0.5.2, extended in `runtime_test.lua`. |
| `tools/check.sh` | Syntax check, tests, then package. |
| `media/logo.png` | CurseForge project logo (source: `media/logo.svg.html`). |
| `tools/package.py` | Verifies versions and pinned hashes, builds `dist/AuctionHouseProfits-<version>.zip`. |

## Develop

```sh
LUA=/path/to/lua5.1 LUAC=/path/to/luac5.1 sh tools/check.sh
```

To try it in game, copy or symlink `AuctionHouseProfits/` into the WoW: Forever
`Interface/AddOns/` folder and restart the client. A `/reload` isn't enough for a
newly added add-on.

The mock tests prove wiring and math, not rendering, taint or exact layout. Check those in game.

## Release

Releases are automatic from an annotated tag on `main`:

1. Bump `## Version` in the TOC and `VERSION` in `Core.lua`, and add a matching `## x.y.z` section to `CHANGELOG.md`.
2. Merge to `main`, then tag and push:
   ```sh
   git tag -a v0.1.1 -m "Auction House Profits 0.1.1"
   git push origin v0.1.1
   ```
3. **Release addon** runs the tests and builds the zip. It publishes a GitHub Release, then uploads
   the same zip to CurseForge for WoW Forever 1.60.1. `vX.Y.Z-alpha.N` and `-beta.N` tags upload as
   alpha and beta files.

CurseForge project: [Auction House Profits (1801565)](https://authors.curseforge.com/#/projects/1801565/files).
Uploads need `## X-Curse-Project-ID` in the TOC and the `CF_API_TOKEN` repository secret
(CurseForge → Author Settings → API Tokens). If either is missing, the
GitHub Release still publishes and the workflow warns that CurseForge was skipped. After fixing
it, re-run **Release addon** with the same tag.

A `curseforge-upload-pending.json` asset on a GitHub Release means an upload started but wasn't
confirmed. Check the project's files on CurseForge before deleting that asset and retrying. This
stops a re-run from uploading the same version twice. The upload API only confirms CurseForge
accepted the file; moderation approval shows on the author dashboard.
