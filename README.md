# Offline Maps for Garmin

A pannable, zoomable map for Garmin watches that ship no cartography of their
own — starting with the **Venu 3** and **Venu 3S**. No phone, no network, no
subscription: the map is compiled into the app.

<p align="center">
  <img src="docs/img/preview-z14.png" width="220" alt="City overview">
  <img src="docs/img/preview-z16.png" width="220" alt="Street level">
  <img src="docs/img/preview-heading-up.png" width="220" alt="Heading-up mode">
</p>

<sub>Rendered from the bundled demo pack by <code>tools/mappack</code>'s preview
renderer, a Python re-implementation of the on-watch drawing code.</sub>

---

## Why

The Venu 3 is a capable watch with no map. Garmin's own cartography is not
available for it — `WatchUi.MapView` is unsupported on this device — and the
Connect IQ map apps that exist stream raster tiles, so they need your phone in
range, an internet connection, and usually a subscription.

This takes the other road: **vector map data, quantised and compiled into the
app**. Once installed it works in a tunnel, on a plane, or abroad with the phone
at the hotel.

## What it does

- Pan by dragging, zoom with on-screen buttons, over the whole packed region
- **Follow me** — recentres on every GPS fix; one tap to re-engage after panning
- **North-up or heading-up** — the map turns with you, with a north arrow
- Roads by class, water, rivers, parks and forests, railways, paths
- Scale bar, dark and light themes, position marker with a heading wedge
- All offline, from a pack you build for your own area

## Quick start

Needs the [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) (free
Garmin account) and Python 3.9+. `make doctor` reports anything missing.

```bash
git clone https://github.com/Chemaclass/garmin-offline-maps.git
cd garmin-offline-maps

make key      # one-off signing key, kept out of git
make build    # compiles with the bundled demo map
make sim      # opens the simulator and side-loads it
```

Then swap the demo for where you actually are — west,south,east,north:

```bash
make pack BBOX=-3.75,40.38,-3.65,40.45 NAME="Madrid"
make build
```

The packer prints a size report. Read it: an over-budget pack produces an app
that will not install, and **[docs/PACKER.md](docs/PACKER.md#budgets)** has the
ceilings and the tuning knobs in the order to reach for them.

## How it works

There is no runtime data path — no network, no filesystem, no companion app.
That shape is forced by four measured limits: 768 KB of app RAM, ~128 KB of
key-value storage, no filesystem API, and under 1 KB/s over BLE.

Three moving parts: `tools/mappack/` (Python, tested), `source/` (Monkey C,
needs the SDK), and a byte format that three implementations must agree on.

**[docs/](docs/README.md)** is the index — the pipeline in 30 seconds, then
architecture, rendering, packer, format, devices, development and publishing.

## Contributing

Most of the interesting work — the packer, the byte format, the look of the map
— needs nothing but `python3`; only `source/` needs a Garmin toolchain. `make
test` runs 67 tests without the SDK.

Start at **[CONTRIBUTING.md](CONTRIBUTING.md)**. Adding a watch model is a good
first change: see [docs/DEVICES.md](docs/DEVICES.md#adding-another-device).

## Licence and attribution

Code is MIT — see [LICENSE](LICENSE).

Map data is **not** covered by it. Packs built from OpenStreetMap are derived
works under the [ODbL](https://opendatacommons.org/licenses/odbl/) and must
credit "© OpenStreetMap contributors"; the app carries that in its About screen
and the packer writes it into every pack. Pack a different source and you set
`--attribution` and check that source's terms yourself — Garmin's review
guidelines put the licensing burden on you.

## Status

No release cut yet; [CHANGELOG.md](CHANGELOG.md) lists what exists today. The
packer, format and rendering maths are covered by tests. The Monkey C compiles
for both products and runs in the simulator, but has **never run on a real
watch** — see [docs/README.md](docs/README.md#status) for what that leaves
unverified.

## Roadmap

- [ ] On-watch timing measurements
- [ ] Waypoints: drop, save, bearing and distance
- [ ] Route overlay from a GPX packed alongside the map
- [ ] Place-name labels (needs a text layer in the format)
- [ ] Widget/glance entry point
- [ ] Connect IQ store release
