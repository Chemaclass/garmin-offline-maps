---
name: sdk
description: Set up, locate or repair the Connect IQ toolchain, then compile/run the watch app. Use when monkeyc is missing, `make build`/`make sim`/`make package` fails before compiling, device definitions for venu3/venu3s are missing, or the user asks to install the Garmin SDK, open the simulator, or side-load to the watch.
---

# Connect IQ toolchain

Full procedure, install commands and the CI route:
**[docs/DEVELOPMENT.md § Setting up the toolchain](../../../docs/DEVELOPMENT.md#setting-up-the-toolchain)**.
Read it — do not improvise an install.

## 1. Diagnose before installing

```bash
make doctor
```

That is the whole diagnosis step; it checks each piece separately and prints the
fix. Four things must exist and they fail with similar-looking errors: missing
SDK binaries give `make: monkeyc: No such file or directory`; missing Java gives
`Unable to locate a Java Runtime`; missing device definitions give
`ERROR: Invalid device id specified: 'venu3'.`; a missing `developer_key` stops
`make build` before it compiles.

## 2. Ask before installing

These are multi-hundred-MB downloads, and device definitions need the user's own
free Garmin account — only they can enter those credentials. Do not try to route
around the login. `temurin@21` is a `.pkg` and needs `sudo`, so the user must run
that one themselves; the other casks you can install.

Device definitions also require accepting the SDK licence agreement in
`SdkManager.app`. An unaccepted agreement leaves the Devices list empty while
looking like a completed login — if `make doctor` still says `MISSING` after the
user reports success, that is the usual cause.

## 3. Build and run

```bash
make build DEVICE=venu3     # and venu3s -- every product in manifest.xml
make sim                    # simulator + side-load
make package                # .iq for the store
```

The Makefile autodetects the Homebrew SDK; `SDK_BIN=` is only for an SDK
installed elsewhere. Never suggest `SDK_BIN="$(brew --prefix)/bin"` — the cask
does not link `connectiq` there, so it builds but breaks `make sim`.

On the watch: plug in over USB, copy the `.prg` into `GARMIN/APPS/`, eject. The
Venu 3 mounts over MTP, not mass storage, so macOS Finder will not show it.

## Build expectations

The app compiles clean for all 24 products under SDK 9.2.0 and runs in the
simulator. It has never run on hardware.

**Zero warnings is the expected state**, on every device. It did not used to be:
`Cannot determine if container access is using container type` fired 36 times
until the subscripted values were annotated, and the launcher icon warned on 20
of the 24 products until `monkey.jungle` grew per-size icon folders. A warning
now means something changed, so read it rather than assuming it is background
noise.

`make build DEVICE=<id>` builds one device. To sweep all of them, read the list
out of the manifest the way CI does:

```bash
for d in $(grep -o 'iq:product id="[^"]*"' manifest.xml | cut -d'"' -f2); do
    make build DEVICE="$d" || echo "FAILED: $d"
done
```
Errors are not expected — if one appears, fix it on its merits and report it; do
not restructure working logic, and do not reach for `-l 0` to silence the type
checker. See the annotation note in docs/DEVELOPMENT.md § Conventions.

`developer_key` is the app's store identity — never print, commit or regenerate.
