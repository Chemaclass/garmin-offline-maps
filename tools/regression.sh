#!/usr/bin/env bash
#
# Everything that can fail, in one run.
#
#   tools/regression.sh            # static gates only, no SDK needed past step 1
#   tools/regression.sh --sim      # also run both packs in the simulator
#
# The simulator half is opt-in because it costs about three minutes and needs a
# 9.1.x SDK. It is also the only half that would have caught this month's bugs:
# every one of them compiled, passed the suite, and then drew the wrong thing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WITH_SIM=0
[ "${1:-}" = "--sim" ] && WITH_SIM=1

PASS=0
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Refuse to run on a dirty tree. Several steps regenerate `mapdata/active` and
# restore it afterwards, and telling that apart from your own edits afterwards
# is not worth the risk.
if [ -n "$(git status --porcelain)" ]; then
    echo "!! worktree is dirty; commit or stash first" >&2
    git status --short >&2
    exit 1
fi

step "Packer"
test_out="$(make test 2>&1)"
case "$test_out" in *$'\nOK'*|*"OK ("*) ok "test suite" ;; *) bad "make test" ;; esac
make lint >/dev/null 2>&1 && ok "lint" || bad "make lint"

step "Generated artefacts"
# Exactly what CI runs. A diff means a generated file was hand-edited or the
# committed demo pack went stale.
make demo >/dev/null 2>&1
if git diff --exit-code --quiet -- mapdata/active source/generated/MapIndex.mc; then
    ok "make demo leaves no diff"
else
    bad "mapdata/active or MapIndex.mc drifted"
    git checkout -- mapdata/active source/generated/MapIndex.mc 2>/dev/null
fi

step "Version contract"
version="$(sed -n 's/.*APP = "\([0-9.]*\)".*/\1/p' source/Version.mc)"
grep -q "## \[$version\]" CHANGELOG.md \
    && ok "Version.mc $version has a CHANGELOG section" \
    || bad "Version.mc $version is not in CHANGELOG.md"

step "Builds, warning-free"
# Read from the manifest rather than hardcoded, or the list drifts the moment
# the listing's products change and the run fails on devices it no longer
# builds. Capped at eight so a full run stays a few minutes; `make package`
# covers every product anyway.
if command -v monkeyc >/dev/null 2>&1 || [ -n "$(ls -d "$(brew --prefix 2>/dev/null)"/Caskroom/connectiq 2>/dev/null)" ]; then
    for device in $(grep -o 'iq:product id="[^"]*"' manifest.xml | cut -d'"' -f2 | head -8); do
        count="$(make build DEVICE="$device" 2>&1 | grep -cE 'WARNING|ERROR')"
        [ "$count" = "0" ] && ok "$device" || bad "$device ($count warnings/errors)"
    done
    # Captured rather than piped into grep: `grep -q` exits on the first match,
    # which SIGPIPEs make, and `pipefail` then calls the whole pipeline failed
    # even though the build succeeded.
    package_out="$(make package 2>&1)"
    case "$package_out" in
        *"BUILD SUCCESSFUL"*) ok "store bundle, every product" ;;
        *) bad "make package" ;;
    esac
else
    echo "  SKIP  no Connect IQ SDK; packer gates above are the whole run"
fi

# --- simulator ------------------------------------------------------------
# Compiling proves nothing about what gets drawn. Both shipping shapes are run
# here: the demo pack that the generic listing carries, and a street-level city,
# which is a different scale of pack and has failed where the demo did not.

run_in_simulator() {  # name, seconds
    pkill -f 'bin/monkeydo' >/dev/null 2>&1
    pgrep -f 'MacOS/simulator' >/dev/null 2>&1 \
        || ("$SIM_BIN/ConnectIQ.app/Contents/MacOS/simulator" >/dev/null 2>&1 &)
    local waited=0
    until nc -z 127.0.0.1 1234 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        [ "$waited" -gt 60 ] && { bad "$1 (simulator never opened its port)"; return; }
    done
    timeout "$2" "$SIM_BIN/monkeydo" bin/offline-maps.prg venu3 > "$LOG_DIR/$1.log" 2>&1
    # "Encountered an app crash" covers the watchdog and any uncaught throw.
    if grep -qiE 'watchdog|exception|Encountered an app crash' "$LOG_DIR/$1.log"; then
        bad "$1 crashed"
        sed -n '/Error:/,$p' "$LOG_DIR/$1.log" | head -8
    else
        ok "$1 ran clean for ${2}s"
    fi
}

if [ "$WITH_SIM" = "1" ]; then
    SIM_BIN="$(ls -d "$HOME"/.Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.1.*/bin 2>/dev/null | tail -1)"
    LOG_DIR="$(mktemp -d)"
    if [ -z "$SIM_BIN" ]; then
        step "Simulator"
        bad "no 9.1.x SDK; 9.2.0's simulator segfaults on draw (docs/DEVELOPMENT.md)"
    else
        step "Simulator: demo pack"
        make build DEVICE=venu3 >/dev/null 2>&1
        run_in_simulator demo 70

        step "Simulator: street-level city"
        # Berlin from cities.json, but packed straight in rather than through
        # build-city.sh: this is about the renderer, not the store bundle.
        if [ -f tools/mappack/berlin.osm ]; then
            (cd tools/mappack && python3 -m mappack \
                --bbox "13.30,52.47,13.48,52.56" --name Berlin --cache berlin.osm \
                --zooms 12,14,15,16 --simplify 2.0 --max-points-per-tile 200 \
                --out "$ROOT/mapdata/active" \
                --index "$ROOT/source/generated/MapIndex.mc") >/dev/null 2>&1
            make build DEVICE=venu3 >/dev/null 2>&1
            run_in_simulator city 90
        else
            echo "  SKIP  needs tools/mappack/berlin.osm (an Overpass cache); see docs/PACKER.md"
        fi
    fi
    pkill -f 'bin/monkeydo' >/dev/null 2>&1
    pkill -f 'MacOS/simulator' >/dev/null 2>&1
fi

# Always leave the tree as we found it: the steps above regenerate the pack.
make demo >/dev/null 2>&1
git checkout -- mapdata/active source/generated/MapIndex.mc 2>/dev/null
git clean -fdq mapdata/active 2>/dev/null

step "Result"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
dirty="$(git status --porcelain | wc -l | tr -d ' ')"
[ "$dirty" = "0" ] || printf '  \033[31m!!\033[0m worktree left dirty (%s files)\n' "$dirty"
[ "$FAIL" = "0" ] && [ "$dirty" = "0" ]
