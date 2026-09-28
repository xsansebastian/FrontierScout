#!/usr/bin/env bash
# Re-vendors the embedded libraries into Libs/ from pinned upstream revisions.
# Bump a pin, run this script, review the diff, commit.
set -euo pipefail

ACE3_REPO="https://github.com/WoWUIDev/Ace3.git"
ACE3_REV="a3604956e6e98a2b41144e7dbffadb21b917f828"          # 2026-09-25, TOC lists 16001
HBD_REPO="https://github.com/Nevcairiel/HereBeDragons.git"
HBD_REV="0547c95f1831f7c68acf3bd29a3c587ca20ce9b7"           # 2026-08-12, minor 33
LIBDEFLATE_REPO="https://github.com/SafeteeWoW/LibDeflate.git"
LIBDEFLATE_REV="1.0.2-release"

ACE3_MODULES=(
  LibStub
  CallbackHandler-1.0
  AceAddon-3.0
  AceEvent-3.0
  AceTimer-3.0
  AceConsole-3.0
  AceDB-3.0
  AceLocale-3.0
  AceComm-3.0
  AceSerializer-3.0
  AceGUI-3.0
  AceConfig-3.0
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBS="$ROOT/Libs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() { # repo rev dir
  git init -q "$3"
  git -C "$3" remote add origin "$1"
  git -C "$3" fetch -q --depth 1 origin "$2"
  git -C "$3" checkout -q FETCH_HEAD
}

fetch "$ACE3_REPO" "$ACE3_REV" "$WORK/ace3"
fetch "$HBD_REPO" "$HBD_REV" "$WORK/hbd"
fetch "$LIBDEFLATE_REPO" "$LIBDEFLATE_REV" "$WORK/libdeflate"

rm -rf "$LIBS"
mkdir -p "$LIBS"

for m in "${ACE3_MODULES[@]}"; do
  cp -R "$WORK/ace3/$m" "$LIBS/$m"
done
cp "$WORK/ace3/LICENSE.txt" "$LIBS/LICENSE-Ace3.txt"

mkdir -p "$LIBS/HereBeDragons-2.0"
cp "$WORK/hbd/HereBeDragons-2.0.lua" "$WORK/hbd/HereBeDragons-Pins-2.0.lua" "$LIBS/HereBeDragons-2.0/"

mkdir -p "$LIBS/LibDeflate"
cp "$WORK/libdeflate/LibDeflate.lua" "$WORK/libdeflate/lib.xml" "$WORK/libdeflate/LICENSE.txt" "$LIBS/LibDeflate/"

cat > "$LIBS/README.md" <<EOF
# Embedded libraries

Vendored by \`scripts/update-libs.sh\`. Do not edit by hand.

| Library | Source | Revision | License |
|---|---|---|---|
| LibStub, CallbackHandler-1.0, Ace3 modules | $ACE3_REPO | \`$ACE3_REV\` | BSD (LICENSE-Ace3.txt) |
| HereBeDragons-2.0 (+ Pins) | $HBD_REPO | \`$HBD_REV\` | BSD |
| LibDeflate | $LIBDEFLATE_REPO | \`$LIBDEFLATE_REV\` | zlib (LibDeflate/LICENSE.txt) |
EOF

echo "Libs updated in $LIBS"
