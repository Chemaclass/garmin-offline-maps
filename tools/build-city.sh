#!/usr/bin/env bash
#
# Build one per-city Connect IQ store bundle.
#
# The map is compiled into the app, so a store listing covers exactly one
# region. Each city therefore needs its own app id and its own app name, which
# live in cities.json. This script swaps those two fields into the tracked
# manifest.xml and strings.xml, builds, and puts them back -- so a failed or
# interrupted build never leaves the repo holding another city's identity.
#
#   tools/build-city.sh berlin
#   tools/build-city.sh --list
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CITIES="$ROOT/cities.json"
MANIFEST="$ROOT/manifest.xml"
STRINGS="$ROOT/resources/strings/strings.xml"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[36m>>\033[0m %s\n' "$*"; }

[ -f "$CITIES" ] || die "no cities.json at $CITIES"

if [ "${1:-}" = "--list" ]; then
    python3 - "$CITIES" <<'PY'
import json, sys
cities = json.load(open(sys.argv[1]))["cities"]
width = max((len(k) for k in cities), default=4)
for slug, c in sorted(cities.items()):
    print(f"  {slug:<{width}}  {c['app_name']:<28} {c['bbox']}")
PY
    exit 0
fi

CITY="${1:-}"
[ -n "$CITY" ] || die "usage: tools/build-city.sh <city>   (or --list)"

# Read and validate the entry before touching anything. Written to a file and
# sourced rather than captured with $( ), because macOS ships bash 3.2 and it
# cannot parse a heredoc inside a command substitution: the script dies with
# "unexpected EOF" before a line of it runs. Validation still aborts here
# rather than sourcing nothing and tripping over an unset variable later.
CITY_ENV="$(mktemp)"
trap 'rm -f "$CITY_ENV"' EXIT
python3 - "$CITIES" "$CITY" > "$CITY_ENV" <<'PY'
import json, re, sys, shlex
path, slug = sys.argv[1], sys.argv[2]
data = json.load(open(path))["cities"]
if slug not in data:
    sys.exit("error: no such city %r in cities.json (try --list)" % slug)
c = data[slug]
for key in ("app_name", "pack_name", "app_id", "bbox"):
    if not c.get(key):
        sys.exit("error: %s is missing %r" % (slug, key))
if not re.fullmatch(r"[0-9a-f]{32}", c["app_id"]):
    sys.exit("error: %s app_id must be 32 lowercase hex chars" % slug)
# A duplicated id would silently publish over another city's listing.
clash = [s for s, o in data.items() if s != slug and o.get("app_id") == c["app_id"]]
if clash:
    sys.exit("error: %s shares its app_id with %s" % (slug, ", ".join(clash)))
for key in ("app_name", "pack_name", "app_id", "bbox"):
    print("%s=%s" % (key.upper(), shlex.quote(c[key])))
for key, default in (("zooms", "12,14,16"), ("simplify", "1.0"), ("extra", "")):
    print("%s=%s" % (key.upper(), shlex.quote(str(c.get(key, default)))))
# Optional: the products this listing covers. The map is compiled into every
# one of them, so a dense city that fits five watches does not fit twenty-four.
print("PRODUCTS=%s" % shlex.quote(" ".join(c.get("products", []))))
PY
. "$CITY_ENV"

say "building $APP_NAME  (id $APP_ID)"

# Restore the tracked files no matter how we leave. The repo must never keep a
# city's identity or pack: the demo pack is what CI checks against.
BACKUP="$(mktemp -d)"
cp "$MANIFEST" "$BACKUP/manifest.xml"
cp "$STRINGS" "$BACKUP/strings.xml"
restore() {
    cp "$BACKUP/manifest.xml" "$MANIFEST"
    cp "$BACKUP/strings.xml" "$STRINGS"
    rm -rf "$BACKUP"
    say "restored manifest.xml and strings.xml"
    make -C "$ROOT" demo >/dev/null 2>&1 && say "restored the demo pack"
}
trap restore EXIT

# python3 rather than sed -i: BSD and GNU sed disagree on -i, and these are
# structured files where a blind regex over the whole document is a bad idea.
python3 - "$MANIFEST" "$STRINGS" "$APP_ID" "$APP_NAME" "$PRODUCTS" <<'PY'
import re, sys
manifest, strings, app_id, app_name, products = sys.argv[1:6]

src = open(manifest, encoding="utf-8").read()
src, n = re.subn(r'(?<=\bid=")[0-9a-f]{32}(?=")', app_id, src, count=1)
if n != 1:
    sys.exit("error: could not find the application id in manifest.xml")

# A listing may cover fewer products than the tracked manifest. The store caps
# a .iq at 15 MB and the map is compiled into every product, so the usable pack
# is 15 MB divided by however many there are. Berlin at full detail fits five
# watches and not twenty-four.
wanted = products.split()
if wanted:
    known = set(re.findall(r'iq:product id="([^"]+)"', src))
    unknown = [p for p in wanted if p not in known]
    if unknown:
        sys.exit("error: products not in manifest.xml: %s" % ", ".join(unknown))
    block = "\n".join('            <iq:product id="%s"/>' % p for p in wanted)
    src, n = re.subn(r"<iq:products>.*?</iq:products>",
                     "<iq:products>\n%s\n        </iq:products>" % block,
                     src, count=1, flags=re.S)
    if n != 1:
        sys.exit("error: could not find the product list in manifest.xml")
open(manifest, "w", encoding="utf-8").write(src)

src = open(strings, encoding="utf-8").read()
escaped = app_name.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
src, n = re.subn(r'(?<=<string id="AppName">)[^<]*(?=</string>)', escaped, src, count=1)
if n != 1:
    sys.exit("error: could not find AppName in strings.xml")
open(strings, "w", encoding="utf-8").write(src)
PY

say "packing $PACK_NAME  ($BBOX)"
# CITY= on purpose. `make city CITY=berlin` exports CITY to this sub-make, and
# the pack target reads CITY as "a place name to geocode", so it would add
# --city berlin beside the --bbox below and the packer would refuse both. The
# two CITYs mean different things: a listing slug here, a search term there.
make -C "$ROOT" pack CITY= \
    BBOX="$BBOX" NAME="$PACK_NAME" ZOOMS="$ZOOMS" SIMPLIFY="$SIMPLIFY" \
    EXTRA="$EXTRA" | tee "$BACKUP/pack.log"

# A budget warning means the app will not install, or installs with the detail
# gutted. Either way it is not something to discover after upload.
if grep -qiE "warn|exceeds|over budget" "$BACKUP/pack.log"; then
    die "the packer warned on this pack -- fix it before publishing (docs/PACKER.md)"
fi

say "building the store bundle"
make -C "$ROOT" package

OUT="$ROOT/bin/offline-maps-$CITY.iq"
mv "$ROOT/bin/offline-maps.iq" "$OUT"

# The store rejects a .iq over 15 MB, and that ceiling is for the whole bundle:
# the map is compiled into every product, so the same pack is paid for once per
# <iq:product> in manifest.xml. Two products cost little; twenty-four turn a
# comfortable pack into a rejected upload. Catch it here rather than at upload.
IQ_BYTES=$(wc -c < "$OUT" | tr -d ' ')
LIMIT=$((15 * 1024 * 1024))
PRODUCTS=$(grep -c 'iq:product id=' "$ROOT/manifest.xml")
if [ "$IQ_BYTES" -gt "$LIMIT" ]; then
    die "$(basename "$OUT") is $((IQ_BYTES / 1024 / 1024)) MB across $PRODUCTS products; the store rejects anything over 15 MB.
     Either shrink the pack (docs/PACKER.md#budgets) or cut the product list in
     manifest.xml for this listing -- the budget is 15 MB / number of products."
fi
say "wrote $(basename "$OUT")  ($(du -h "$OUT" | cut -f1), $PRODUCTS products)"
say "upload it at https://apps-developer.garmin.com"
