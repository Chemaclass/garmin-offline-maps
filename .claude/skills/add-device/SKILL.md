---
name: add-device
description: Add support for another Garmin watch (vivoactive5, venu2, fr265, fr965, …). Use when the user wants the app to run on a model beyond venu3/venu3s, asks whether a watch is supported, or hits a memory/screen-size problem on a new device.
---

# Adding a device

Support is a memory question first and a product-id question second.

The checklist and the candidate list are in
[docs/DEVICES.md § Adding another device](../../../docs/DEVICES.md#adding-another-device).
Look the model up there **before editing anything** — that page has the real
numbers and their sources.

## What decides viability

Watch-app memory versus the off-screen buffer, which is roughly
`width × height / 2` bytes at 4 bpp. `MapRenderer` falls back to drawing
straight to the screen when allocation fails, so a tight device degrades rather
than crashes — but it degrades into a visibly worse map, and that is worth
saying out loud rather than reporting the device as supported.

Beyond memory: touch screen, round display, and API level ≥ `minApiLevel` in
`manifest.xml`.

## Then

1. Add `<iq:product id="..."/>` to `manifest.xml`.
2. Update the `for device in venu3 venu3s` loop in `.github/workflows/ci.yml` —
   it lists devices literally.
3. Download the device definition, then `make build DEVICE=<id>` and
   `make sim DEVICE=<id>`. See the `sdk` skill if the toolchain is not set up.
4. Only if the screen is much larger: a bigger viewport shows more tiles at
   once, raising peak `TileStore` residency. Preview at the new size first
   (`python3 -m mappack.preview --size <px> --zoom 16 --out p.png`), and repack
   with a lower `--max-points-per-tile` if it stutters.

## Name the devices you built for

A manifest edit is not support — run `make build DEVICE=<id>` for each one and
report the devices that actually compiled.
