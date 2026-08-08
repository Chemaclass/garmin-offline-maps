---
name: sdk
description: Set up, locate or repair the Connect IQ toolchain, then compile/run the watch app. Use when monkeyc is missing, `make build`/`make sim`/`make package` fails before compiling, device definitions for venu3/venu3s are missing, or the user asks to install the Garmin SDK, open the simulator, or side-load to the watch.
---

# Connect IQ toolchain

Full procedure, install commands and the CI route:
**[docs/DEVELOPMENT.md § Setting up the toolchain](../../../docs/DEVELOPMENT.md#setting-up-the-toolchain)**.
Read it, do not improvise an install.

## 1. Diagnose before installing

```bash
make doctor
```

That is the whole diagnosis step; it checks each piece separately and prints the
fix. **Six** things must exist and they fail with similar-looking errors:

| Missing | Symptom |
|---|---|
| SDK binaries | `make: monkeyc: No such file or directory` |
| Java runtime | `Unable to locate a Java Runtime` |
| Device definitions | `ERROR: Invalid device id specified: 'venu3'.` |
| `developer_key` | `make build` stops before compiling |
| A 9.1.x SDK for the simulator | window appears for a second and vanishes, `monkeydo` still exits 0 |
| `libmtp` | `make watch` says `mtp-detect not found` |

**The simulator needs an older SDK than the compiler.** 9.2.0's simulator
segfaults on macOS 26 the moment an app draws, including on Garmin's own
samples, and it fails quietly: `monkeydo` exits 0, so from the terminal it looks
like it worked. `make sim` looks for a `connectiq-sdk-mac-9.1.*` under
`~/.Garmin/ConnectIQ/Sdks/`. This is the single most expensive trap in the
toolchain; check it before believing any "the app does not run" report.

## 2. Ask before installing

These are multi-hundred-MB downloads, and device definitions need the user's own
free Garmin account; only they can enter those credentials. Do not try to route
around the login. `temurin@21` is a `.pkg` and needs `sudo`, so the user must run
that one themselves; the other casks you can install.

Device definitions also require accepting the SDK licence agreement in
`SdkManager.app`. An unaccepted agreement leaves the Devices list empty while
looking like a completed login. If `make doctor` still says `MISSING` after the
user reports success, that is the usual cause.

## 3. Build and run

```bash
make build DEVICE=venu3     # and venu3s -- every product in manifest.xml
make sim                    # simulator + side-load; prints System.println output
make watch                  # side-load to a watch on USB (needs libmtp)
make catalogue CITY=Berlin  # serve a downloadable city, for the download path
make package                # .iq for the store
```

The Makefile autodetects the Homebrew SDK; `SDK_BIN=` is only for an SDK
installed elsewhere. Never suggest `SDK_BIN="$(brew --prefix)/bin"`: the cask
does not link `connectiq` there, so it builds but breaks `make sim`.

On the watch: `make watch`. Garmin watches speak MTP, which macOS does not
mount natively, hence `libmtp` rather than a copy into `/Volumes`. **The watch
must be awake** or it drops off the bus, and `libmtp` then reports
`No raw devices found` exactly as though it were unplugged. Quit Garmin Express,
which holds the device.

If the side-load port stays shut, an instance is wedged:

```bash
pkill -f 'bin/monkeydo'; pkill -f 'MacOS/simulator'
```

## Build expectations

The app compiles clean for all 24 products under SDK 9.2.0 and runs in the
9.1.0 simulator.

**What the simulator does not do**, because reports of "it works" keep resting
on it: it produces no GPS fix and no compass heading, so the whole follow path
is dead code there; and it persists app settings per app, so editing a default
in the generated `resources/settings/properties.xml` reaches nothing.

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
Errors are not expected. If one appears, fix it on its merits and report it; do
not restructure working logic, and do not reach for `-l 0` to silence the type
checker. See the annotation note in docs/DEVELOPMENT.md § Conventions.

`developer_key` is the app's store identity: never print, commit or regenerate.
