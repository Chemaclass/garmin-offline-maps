#!/usr/bin/env bash
#
# Build and side-load onto a watch plugged in over USB.
#
# The point of this is the loop it replaces. Going through the store means
# upload, review, phone sync, then watch update, for every one-line change;
# this is a few seconds and needs neither a phone nor an internet connection.
# Releases stay for when a build is worth publishing, not for testing one.
#
#   tools/push-watch.sh                # venu3
#   tools/push-watch.sh venu3s         # another device
#
# Garmin watches speak MTP, which macOS does not mount natively, hence libmtp
# rather than a copy into /Volumes:  brew install libmtp
#
# The watch must be awake. It drops off the bus when the screen sleeps, and
# libmtp then reports "No raw devices found" as though it were unplugged.
set -euo pipefail

DEVICE="${1:-venu3}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRG="$ROOT/bin/offline-maps.prg"

for tool in mtp-detect mtp-folders mtp-sendfile; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "!! $tool not found. brew install libmtp" >&2
        exit 1
    }
done

echo ">> building for $DEVICE"
make -C "$ROOT" build DEVICE="$DEVICE"

# Fail here rather than half way through a transfer, and say which of the two
# likely causes it is: asleep and unplugged look identical to libmtp.
echo ">> looking for the watch"
if ! mtp-detect 2>&1 | grep -q "Found 1 device"; then
    echo "!! no watch on USB. Check the cable carries data, wake the screen," >&2
    echo "   and quit Garmin Express if it is running." >&2
    exit 1
fi

# The app folder id is not stable across devices or firmware, so look it up
# rather than hardcoding it.
echo ">> finding GARMIN/APPS"
FOLDER_ID="$(mtp-folders 2>/dev/null \
    | awk '/^[0-9]+[[:space:]]+APPS$/ { print $1; exit }')"
if [ -z "$FOLDER_ID" ]; then
    echo "!! could not find an APPS folder. Folders seen:" >&2
    mtp-folders 2>/dev/null | head -40 >&2
    exit 1
fi

# Overwrite rather than accumulate: MTP will happily store a second file with
# the same name, and the watch then shows the app twice.
OLD_ID="$(mtp-files 2>/dev/null \
    | awk '/^File ID:/ { id=$3 } /Filename: offline-maps\.prg$/ { print id; exit }')"
if [ -n "$OLD_ID" ]; then
    echo ">> removing the previous copy ($OLD_ID)"
    mtp-delfile -n "$OLD_ID" >/dev/null 2>&1 || true
fi

echo ">> sending $(basename "$PRG") to folder $FOLDER_ID"
mtp-sendfile -f "$FOLDER_ID" "$PRG" offline-maps.prg

echo ">> done. Unplug, then open Offline Maps. Check About for the version."
