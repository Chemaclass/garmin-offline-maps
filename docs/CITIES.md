# Downloadable cities

One app, any city, chosen on the phone. The city is typed into the Connect IQ
settings, and the watch fetches it from a static catalogue.

This is a **second kind of map**, not a smaller version of the compiled-in one.
Read the trade below before assuming it replaces a packed region.

## What the user does

**On the watch**, which is the easy way: hold the screen to open the menu, then
**Change city**. The watch fetches the catalogue and lists what is published;
pick one and it downloads, with progress on screen.

**On the phone**, in Garmin Connect's settings for the app, the **City** field
takes the same name. It is free text, so it is normalised before use: `Berlin`,
`berlin` and `New York` all resolve. Leave it empty for the built-in map.

Either way the built-in map keeps drawing until the download finishes, and the
two stay in step: choosing on the watch writes the phone setting back.

## What it costs

`Application.Storage` is the ceiling and it decides everything: about **128 KB
in total**, **8 KB per value**, and it holds strings rather than byte arrays, so
a block is base64 both on the wire and at rest.

Measured against Berlin, the densest city likely to be asked for, at one data
zoom over a 6 km radius:

| Profile | Stored | Verdict |
|---|---|---|
| simplify 2.0, 1100 pts | 328 KB | 3x over |
| simplify 4.0, 300 pts | 103 KB | no headroom |
| **simplify 4.0, 260 pts** | **110 KB** | the profile |
| simplify 6.0, 200 pts | 71 KB | too sparse to read |
| add z16, street level | 1.62 MB | 13x over |

110 KB against a ~128 KB ceiling is still too tight, which is what the radius
is for: the same profile over 5 km gives **71 KB**.

So a downloaded city is **an orientation map**: motorways, primaries,
secondaries, water, rail and parks. No residential streets. Within the budget
the packer spends its points on the highest-priority layers first (see
`classify.py`), and residential does not survive. Street-level detail can only
be compiled in, which is what `make pack` and a per-listing build are for.

Berlin is 20 blocks and 71 KB, roughly 70 seconds over a link that manages
under 1 KB/s. The radius is the other half of that number: the same city at
6 km comes to 110 KB, which is too close to the ceiling to be comfortable, so
`--radius-km` defaults to 5.

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

That geocodes the name, fetches from Overpass, crops to `--radius-km`, packs at
the download profile, and rewrites the catalogue. A city that will not fit is
**reported and skipped** rather than written, because a half-downloaded city is
worse than an absent one.

Overpass is a shared free service and will return 429 to a batch that hammers
it. The publisher paces its fetches, waits out a rate limit rather than dying on
it, and isolates a failure to the city that caused it. The catalogue is rebuilt
from the cities on disk rather than from the ones this run happened to build, so
an interrupted batch never drops previously published cities.

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
