---
name: add-device
description: Add support for another Garmin watch (vivoactive5, venu2, fr265, fr965, …). Use when the user wants the app to run on a model beyond venu3/venu3s, asks whether a watch is supported, or hits a memory/screen-size problem on a new device.
---

# Adding a device

Support is a memory question first and a product-id question second.

## 1. Check it can hold the buffer

Look the model up in `docs/DEVICES.md` before editing anything. What decides
viability is **watch-app memory** (Venu 3 has 768 KB) versus the off-screen
`BufferedBitmap`: roughly `width × height / 2` bytes at 4 bpp, so ~103 KB at
454×454, ~76 KB at 390×390. `MapRenderer` falls back to drawing straight to the
screen when allocation fails, so a tight device degrades rather than crashes —
but it degrades into a visibly worse map, which is worth saying out loud.

Requirements beyond memory: touch screen, round display, API level ≥ 4.2.1
(`manifest.xml`'s `minApiLevel`). README's shortlist of good candidates:
`vivoactive5`, `venu2`, `venu2s`, `venu2plus`, `fr165`, `fr265`, `fr965`.

## 2. Declare it

```xml
<iq:products>
    <iq:product id="venu3"/>
    <iq:product id="venu3s"/>
    <iq:product id="vivoactive5"/>   <!-- new -->
</iq:products>
```

Then the two places that list devices literally:

- `.github/workflows/ci.yml` — the `for device in venu3 venu3s` build loop.
- `Makefile`'s `DEVICE ?= venu3` is only the default; leave it.

## 3. Build and look at it

```bash
connect-iq-sdk-manager device download --manifest=manifest.xml   # or SdkManager.app
make build DEVICE=<new-id>
make sim DEVICE=<new-id>
```

A device definition must exist locally or `monkeyc -d <id>` fails — see the
`sdk` skill.

## 4. Consider the pack

Only if the screen is much bigger than the Venu 3's 454×454: a larger viewport
shows more tiles at once, which raises peak `TileStore` residency. `make pack`
again with a lower `--max-points-per-tile` if the map stutters. Preview at the
new size first: `python3 -m mappack.preview --size <px> --zoom 16 --out p.png`.

## 5. Say what you did not verify

Anything not compiled and run in the simulator is untested. Say which devices
you actually built for, and do not describe a device as supported on the
strength of a manifest edit.
