"""Downloadable city packs, and the catalogue the watch picks from.

A compiled-in pack lives in the `.prg` and can be megabytes. A *downloadable*
pack has to survive a much meaner set of limits, and those limits, not taste,
dictate the shape of everything here:

* `Application.Storage` holds **strings, not byte arrays**, so a block is
  base64 on the wire and in storage. That is 4 bytes stored per 3 bytes of map.
* A single stored value is capped at **8 KB** (the Core Topics figure; the API
  reference says 32 KB and the truth is device-dependent, so we plan for the
  smaller). A block must therefore stay under `MAX_BLOCK_BINARY` bytes so its
  base64 form fits.
* Total storage is about **128 KB**, which is the real ceiling on a city.
* BLE moves under 1 KB/s, so the whole download is a couple of minutes and
  wants to be resumable, one small request at a time.

Hence the layout, served as static files:

    catalogue.json          every city: slug, name, centre, size
    <slug>/meta.json        bounds, zooms, block origins, block keys
    <slug>/b<key>.json      one block, base64, one Storage value

The block bytes are the same MapPack blocks `emit.py` writes into resources.
Nothing about the byte format changes: `TileReader.mc` reads a downloaded block
and a compiled-in one with the same code.
"""

from __future__ import annotations

import base64
import json
import os
from typing import Dict, List, Sequence, Tuple

from .emit import KEY_MAX, KEY_SHIFT, block_origins
from .pack import FORMAT_VERSION, PackOptions, PackResult

#: Cap on one stored value. Conservative on purpose, see the module docstring.
MAX_STORAGE_VALUE = 8000

#: Binary bytes whose base64 still fits `MAX_STORAGE_VALUE`, with room for the
#: JSON quoting around it.
MAX_BLOCK_BINARY = (MAX_STORAGE_VALUE - 64) * 3 // 4

#: Total storage a city may occupy, base64 included.
STORAGE_BUDGET = 120 * 1024

#: What a downloadable pack is packed with.
#:
#: **A downloaded city is an orientation map, not a street map.** That is not a
#: tuning choice, it is what 128 KB buys. Measured against Berlin, the densest
#: city anyone is likely to ask for, at one data zoom:
#:
#:     simplify 2.0, 1100 pts -> 328 KB stored    (3x over budget)
#:     simplify 4.0,  300 pts -> 103 KB
#:     simplify 4.0,  260 pts ->  ~90 KB          <- this
#:     simplify 6.0,  200 pts ->  71 KB           (too sparse to read)
#:
#: Adding z16 takes the same city to 1.62 MB, so street-level detail can only
#: ever be compiled in. Within the budget the packer spends points on the
#: highest-priority layers first (see classify.py), so what survives is
#: motorways, primaries, secondaries, water, rail and parks. Residential
#: streets do not. Renders of this profile are in docs/PACKER.md.
DOWNLOAD_PROFILE = dict(
    data_zooms=(14,),
    min_display_zoom=13,
    max_display_zoom=15,
    simplify_px=4.0,
    max_points_per_tile=260,
    block_target_bytes=MAX_BLOCK_BINARY,
)


def download_options(name: str) -> PackOptions:
    """PackOptions for a city meant to be downloaded rather than compiled in."""
    return PackOptions(name=name, **DOWNLOAD_PROFILE)


def block_key(zoom_slot: int, block_x: int, block_y: int,
              origin_x: int, origin_y: int) -> int:
    """The same relative key `MapIndex.blockResource` computes on the watch."""
    rel_x, rel_y = block_x - origin_x, block_y - origin_y
    if rel_x < 0 or rel_y < 0 or rel_x > KEY_MAX or rel_y > KEY_MAX:
        raise ValueError("block %d/%d is outside the key range for this pack"
                         % (block_x, block_y))
    return (rel_x << KEY_SHIFT) | rel_y


class TooBig(Exception):
    """The city does not fit the watch's storage budget."""


def write_city(result: PackResult, options: PackOptions, slug: str,
               out_dir: str, attribution: str,
               country: str = "Other") -> Dict[str, object]:
    """Write `<out_dir>/<slug>/` and return its catalogue entry.

    Raises `TooBig` rather than writing something the watch will refuse
    halfway through downloading.
    """
    city_dir = os.path.join(out_dir, slug)
    os.makedirs(city_dir, exist_ok=True)

    data_zooms = sorted(set(options.data_zooms))
    origins = block_origins(result)

    oversize = [k for k, v in result.blocks.items() if len(v) > MAX_BLOCK_BINARY]
    if oversize:
        largest = max(len(result.blocks[k]) for k in oversize)
        raise TooBig(
            "%s: %d block(s) exceed the %d byte storage limit (largest %d). "
            "Lower --max-points-per-tile or raise --simplify."
            % (slug, len(oversize), MAX_BLOCK_BINARY, largest)
        )

    keys: List[int] = []
    total_stored = 0
    for (zoom, block_x, block_y), data in sorted(result.blocks.items()):
        slot = data_zooms.index(zoom)
        origin_x, origin_y = origins[zoom]
        key = block_key(slot, block_x, block_y, origin_x, origin_y)
        encoded = base64.b64encode(data).decode("ascii")
        path = os.path.join(city_dir, "b%d.json" % key)
        with open(path, "w", encoding="utf-8") as fh:
            # An object, not the one-element array the compiled-in resources
            # use. `Communications.makeWebRequest` types its callback data as
            # `Dictionary or String or Null`, so an array response is a branch
            # the Monkey C type checker proves unreachable.
            json.dump({"b": encoded}, fh, separators=(",", ":"))
        keys.append(key)
        total_stored += len(encoded)

    if total_stored > STORAGE_BUDGET:
        raise TooBig(
            "%s: %d KB of blocks exceeds the %d KB storage budget. "
            "Shrink the radius or raise --simplify."
            % (slug, total_stored // 1024, STORAGE_BUDGET // 1024)
        )

    west, south, east, north = result.bounds
    center_lon, center_lat = result.center
    meta = {
        "format": FORMAT_VERSION,
        "slug": slug,
        "name": options.name,
        "attribution": attribution,
        "dataZooms": data_zooms,
        "minZoom": options.min_display_zoom,
        "maxZoom": options.max_display_zoom,
        "blockLog2": [result.block_log2.get(z, 3) for z in data_zooms],
        "originX": [origins.get(z, (0, 0))[0] for z in data_zooms],
        "originY": [origins.get(z, (0, 0))[1] for z in data_zooms],
        "keyShift": KEY_SHIFT,
        "west": round(west, 7), "south": round(south, 7),
        "east": round(east, 7), "north": round(north, 7),
        "centerLon": round(center_lon, 7), "centerLat": round(center_lat, 7),
        "blocks": keys,
        "storedBytes": total_stored,
        "country": country,
    }
    with open(os.path.join(city_dir, "meta.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, separators=(",", ":"), sort_keys=True)

    return entry_from_meta(meta, slug)


def entry_from_meta(meta: Dict[str, object], slug: str) -> Dict[str, object]:
    """The catalogue's view of one city, derived from its `meta.json`.

    The only producer of a catalogue entry. There were two, and they had
    already drifted: `write_city` rounded the centre to 5 decimals while
    `scan_published` passed through the 7 that `meta.json` carries. Since the
    catalogue is built from `scan_published`, the published file has seven and
    the rounding never meant anything. Deriving both from the meta is what
    stops an entry disagreeing with the file it describes.

    `slug` is the directory the city was found in. It stands in for a key a
    truncated `meta.json` is missing, and it is the right value to stand in
    with: the watch builds every block URL from it.
    """
    return {
        "slug": meta.get("slug", slug),
        "name": meta.get("name", slug),
        "country": meta.get("country", "Other"),
        "lat": meta.get("centerLat"),
        "lon": meta.get("centerLon"),
        "blocks": len(meta.get("blocks", [])),
        "storedBytes": meta.get("storedBytes", 0),
    }


def scan_published(out_dir: str) -> List[Dict[str, object]]:
    """Catalogue entries for every city already written under `out_dir`.

    The catalogue is derived from what is on disk rather than from what this
    run happened to build. A batch that dies halfway through (Overpass rate
    limits are a fact of life) must not publish a catalogue that forgets the
    cities from previous runs.
    """
    entries: List[Dict[str, object]] = []
    if not os.path.isdir(out_dir):
        return entries
    for slug in sorted(os.listdir(out_dir)):
        meta_path = os.path.join(out_dir, slug, "meta.json")
        if not os.path.isfile(meta_path):
            continue
        with open(meta_path, encoding="utf-8") as fh:
            meta = json.load(fh)
        entries.append(entry_from_meta(meta, slug))
    return entries


def write_catalogue(entries: Sequence[Dict[str, object]], out_dir: str,
                    base_url: str) -> str:
    """The index the settings page and the watch both read."""
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "catalogue.json")
    payload = {
        "format": FORMAT_VERSION,
        "baseUrl": base_url.rstrip("/"),
        # Sorted by country then name so the watch can build its two-level
        # picker by walking the list once, with no sorting on a 768 KB heap.
        # `_ordered` is that order, and the settings dropdown reads it too: a
        # second copy here would let the two drift and mis-map every index.
        "cities": _ordered(entries),
    }
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=1, sort_keys=True)
        fh.write("\n")
    return path


def write_settings_xml(entries: Sequence[Dict[str, object]], path: str,
                       base_url: str) -> str:
    """Generate `resources/settings/settings.xml`.

    The city is a **numbered dropdown**, and the numbering is the interesting
    part. Connect IQ parses a `listEntry` value against the property's type and
    a list wants a number, so a string value is rejected outright with
    `For input string: "..."`. The app therefore stores an index and maps it
    back to a slug through the table in `write_city_list_mc`.

    Entries read "Country: City" because the schema has no cascading lists:
    `settingConfig type="list"` takes only static children, and the one
    dependency mechanism (`group enableIfTrue`) gates a group on a boolean.
    A country dropdown that filtered a city dropdown cannot be expressed, so
    the country goes in the label and one control does the work of two.

    The consequence, and it is unavoidable: this list is compiled into the app,
    so a city published after a release will not appear here until the next
    one. The picker on the watch reads the live catalogue and has no such
    limit, which is why both exist.

    `packBaseUrl` is deliberately not exposed. It has a working default and a
    wrong value silently breaks every download.
    """
    lines = [
        '<!-- GENERATED by tools/mappack. Do not edit. -->',
        '<settings xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"',
        '          xsi:noNamespaceSchemaLocation='
        '"https://developer.garmin.com/downloads/connect-iq/resources.xsd">',
        '    <setting propertyKey="@Properties.cityIndex" title="@Strings.SettingCity"',
        '             prompt="@Strings.SettingCityPrompt"',
        '             helpUrl="%s">' % _escape(site_of(base_url)),
        '        <settingConfig type="list">',
        '            <listEntry value="0">@Strings.SettingCityBuiltIn</listEntry>',
    ]
    for i, city in enumerate(_ordered(entries), start=1):
        label = "%s: %s" % (city.get("country", ""), city["name"])
        lines.append('            <listEntry value="%d">%s</listEntry>'
                     % (i, _escape(label.strip(": "))))
    lines += [
        '        </settingConfig>',
        '    </setting>',
        '</settings>',
        '',
    ]
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    return path


def site_of(base_url: str) -> str:
    """The website that hosts a pack base URL.

    `.../garmin-offline-maps/packs` -> `.../garmin-offline-maps`. Naive
    rsplit turned a short URL such as `https://example.test` into `https:/`,
    so only a trailing packs segment is removed.
    """
    trimmed = base_url.rstrip("/")
    if trimmed.endswith("/packs"):
        return trimmed[: -len("/packs")]
    return trimmed


def _ordered(entries: Sequence[Dict[str, object]]) -> List[Dict[str, object]]:
    """The one order: country, then city.

    The catalogue, the settings dropdown and `CityList` all sort through here.
    The dropdown stores a number, so an index only means a city while the three
    agree; a second copy of this key function is how they would stop agreeing.
    """
    return sorted(entries, key=lambda c: (str(c.get("country", "")), str(c["name"])))


def write_city_list_mc(entries: Sequence[Dict[str, object]], path: str) -> str:
    """Generated Monkey C mapping a settings index back to a slug.

    Index 0 is the built-in map, so the slugs start at 1 and the array is
    offset by one. Kept in step with `write_settings_xml` by being generated
    from the same list in the same order.
    """
    slugs = ['"%s"' % str(c["slug"]).replace('"', "") for c in _ordered(entries)]
    body = [
        "//",
        "// GENERATED FILE -- DO NOT EDIT.",
        "// Produced by tools/mappack. Re-run the publish workflow to regenerate.",
        "//",
        "",
        "import Toybox.Lang;",
        "",
        "//! The cities offered by the phone settings dropdown.",
        "//!",
        "//! Connect IQ list settings store a number, so the phone hands back an",
        "//! index and this turns it back into a catalogue slug. Index 0 means the",
        "//! built-in map, hence the offset.",
        "//!",
        "//! This is only what was published when the app was built. The picker on",
        "//! the watch reads the live catalogue and is not limited to it.",
        "module CityList {",
        "",
        "    const SLUGS = [%s];" % ", ".join(slugs),
        "",
        "    //! Slug for a settings index, or null for the built-in map.",
        "    function slugAt(index) {",
        "        if (index == null || index <= 0 || index > SLUGS.size()) {",
        "            return null;",
        "        }",
        "        return SLUGS[index - 1];",
        "    }",
        "",
        "    //! Settings index for a slug, or 0 when it is not in this build.",
        "    function indexOf(slug) {",
        "        if (slug == null) { return 0; }",
        "        for (var i = 0; i < SLUGS.size(); i += 1) {",
        "            if (SLUGS[i].equals(slug)) { return i + 1; }",
        "        }",
        "        return 0;",
        "    }",
        "}",
        "",
    ]
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(body))
    return path


def write_properties_xml(path: str, base_url: str) -> str:
    lines = [
        '<!-- GENERATED by tools/mappack. Do not edit. -->',
        '<properties>',
        # The dropdown writes this one.
        '    <property id="cityIndex" type="number">0</property>',
        # Written by the watch picker, and the value the app actually uses. Not
        # exposed as a setting: it is an implementation detail of the dropdown.
        '    <property id="cityId" type="string"></property>',
        # Last index the app acted on, so a change made on the phone can be
        # told apart from one made on the watch.
        '    <property id="citySeen" type="number">0</property>',
        '    <property id="packBaseUrl" type="string">%s</property>' % _escape(base_url),
        '</properties>',
        '',
    ]
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    return path


def _escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
