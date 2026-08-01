#!/usr/bin/env bash
# PostToolUse(Edit|Write|MultiEdit): remind about this repo's cross-file
# invariants right after a file that participates in one is touched.
#
# Exit 2 feeds stderr back to Claude as context. The edit has already been
# applied -- this is a nudge, not a block.
set -uo pipefail

payload=$(cat)
file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "$file" ] || exit 0

case "$file" in
  */mappack/pack.py|*/mappack/emit.py|*/mappack/varint.py|*/mappack/decode.py|*/source/TileReader.mc)
    cat >&2 <<'EOF'
CONTRACT: the MapPack byte format has three implementations that must agree:
  tools/mappack/mappack/{pack,emit,varint}.py  (writer)
  tools/mappack/mappack/decode.py              (reference reader, mirrors TileReader.mc line for line)
  source/TileReader.mc                         (on-watch reader)
You just edited one. Check the other two, update docs/FORMAT.md if the bytes
moved, and run `make test` (tests/test_format.py round-trips writer vs reader).
EOF
    exit 2
    ;;
  */source/Palette.mc|*/mappack/classify.py)
    cat >&2 <<'EOF'
CONTRACT: layer ids are shared across languages.
  classify.py L_WATER_AREA=0 .. L_MOTORWAY=9
must line up index-for-index with the first 10 entries of Palette.NIGHT,
Palette.DAY, WIDTH_FAR and WIDTH_NEAR. preview.py *parses* source/Palette.mc at
runtime, so a formatting change there can break the preview tests. Run `make test`.
EOF
    exit 2
    ;;
  */source/generated/*|*/mapdata/active/*)
    cat >&2 <<'EOF'
GENERATED FILE: mapdata/active/** and source/generated/MapIndex.mc are written
by tools/mappack. Hand-edits are overwritten and CI fails on the diff
(`make demo` + `git diff --exit-code`). Regenerate instead: `make demo`, or
`make pack BBOX=...` for a real area.
EOF
    exit 2
    ;;
  */manifest.xml)
    cat >&2 <<'EOF'
manifest.xml touched. If you added an <iq:product>, check docs/DEVICES.md for
that model's watch-app memory -- the off-screen BufferedBitmap is the first
thing that fails to allocate on a tighter device -- and build it explicitly:
`make build DEVICE=<id>`. CI's build loop lists devices literally; update it too.
EOF
    exit 2
    ;;
esac
exit 0
