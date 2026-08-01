# Downloadable cities

One app, any city, chosen on the phone. The city is typed into the Connect IQ
settings, and the watch fetches it from a static catalogue.

This is a **second kind of map**, not a smaller version of the compiled-in one.
Read the trade below before assuming it replaces a packed region.

## What the user does

1. Garmin Connect, the app's Settings, **City**: type a slug such as `berlin`.
2. The watch downloads it the next time the app runs, showing progress.
3. The built-in map keeps drawing until the download completes.

`City` empty, or `builtin`, means the map compiled into the app.

## What it costs

`Application.Storage` is the ceiling and it decides everything: about **128 KB
in total**, **8 KB per value**, and it holds strings rather than byte arrays, so
a block is base64 both on the wire and at rest.

Measured against Berlin at one data zoom:

| Profile | Stored | Verdict |
|---|---|---|
| simplify 2.0, 1100 pts | 328 KB | 3x over |
| simplify 4.0, 300 pts | 103 KB | no headroom |
| **simplify 4.0, 260 pts** | **93 KB** | the profile |
| simplify 6.0, 200 pts | 71 KB | too sparse to read |
| add z16, street level | 1.62 MB | 13x over |

So a downloaded city is **an orientation map**: motorways, primaries,
secondaries, water, rail and parks. No residential streets. Within the budget
the packer spends its points on the highest-priority layers first (see
`classify.py`), and residential does not survive. Street-level detail can only
be compiled in, which is what `make pack` and a per-listing build are for.

Berlin is 30 blocks and 93 KB, roughly 90 seconds over a link that manages
under 1 KB/s.

## Publishing a city

Packs are static files under `docs/packs/`, which GitHub Pages serves from the
`main` branch with no server and no workflow:

```
docs/packs/catalogue.json        every city: slug, name, centre, size
docs/packs/<slug>/meta.json      bounds, zooms, block origins, block keys
docs/packs/<slug>/b<key>.json    one block, {"b": "<base64>"}
```

Add one with:

```bash
cd tools/mappack
python3 -m mappack.publish --city "Madrid" --out ../../docs/packs
```

That geocodes the name, fetches from Overpass, packs at the download profile,
and rewrites the catalogue. A city that will not fit is **reported and skipped**
rather than written, because a half-downloaded city is worse than an absent one.

Adding a city needs no app update. That is why the setting is a text field
rather than a dropdown: a dropdown is compiled into the app, so every new city
would mean a new release. (Connect IQ also parses `listEntry` values against the
property type and rejects a string one, which is how this was found.)

## How it fits together

`Pack` is the seam. Everything that used to read the generated `MapIndex` now
asks `Pack`, which answers from either the compiled-in index or a downloaded
city's metadata, so nothing else knows which is in play.

| Piece | Job |
|---|---|
| `Pack.mc` | bounds, zooms, block lookup, whichever pack is active |
| `CityStore.mc` | the downloaded city in `Application.Storage`, one block per value |
| `CityDownloader.mc` | one request per block, strictly sequential |
| `DownloadView.mc` | progress, and Back to cancel |
| `citypack.py` | writes the static files, and refuses a city that will not fit |

Block bytes are unchanged MapPack blocks, so `TileReader.mc` reads a downloaded
block with exactly the code it uses for a compiled-in one. The byte format has
not moved: see [FORMAT.md](FORMAT.md).

A download writes metadata first with `complete: false`, then the blocks, then
flips the flag. Anything interrupted is cleared rather than drawn, so a partial
city can never render as a map with holes in it.

Only one city is stored at a time. Two would not fit.
