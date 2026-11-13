#!/bin/sh
# Syntax-check every Lua file, run the offline tests, then build the zip.
# Needs Lua 5.1: set LUA=/path/to/lua5.1 (and LUAC) if it isn't on PATH.
set -eu
cd "$(dirname "$0")/.."
LUA="${LUA:-lua5.1}"
LUAC="${LUAC:-luac5.1}"
for f in AuctionHouseProfits/*.lua AuctionHouseProfits/Libs/SomethingNeedDoing/*.lua; do
  "$LUAC" -p "$f"
done
"$LUA" tests/model_test.lua
"$LUA" tests/runtime_test.lua
python3 tools/package.py
