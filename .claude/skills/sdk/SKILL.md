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
which monkeyc monkeydo connectiq
java -version 2>&1 | head -2
ls ~/Library/Application\ Support/Garmin/ConnectIQ/Devices/ 2>/dev/null
```

Three separate things must exist and they fail with similar-looking errors:
missing SDK binaries give `make: monkeyc: No such file or directory`; missing
Java gives `Unable to locate a Java Runtime`; missing device definitions let
`monkeyc` start and then fail on `-d venu3`.

## 2. Ask before installing

These are multi-hundred-MB downloads, and device definitions need the user's own
free Garmin account — only they can enter those credentials. Do not try to route
around the login.

## 3. Build and run

```bash
make build DEVICE=venu3     # and venu3s -- every product in manifest.xml
make sim                    # simulator + side-load
make package                # .iq for the store
make build SDK_BIN=...      # if you would rather not touch PATH
```

On the watch: plug in over USB, copy the `.prg` into `GARMIN/APPS/`, eject.

## Expect compile errors on the first build

This Monkey C has never been through `monkeyc`. The first real build is a
bug-finding exercise, not a smoke test. Fix each error on its merits and report
it; do not restructure working logic to silence a message.

`developer_key` is the app's store identity — never print, commit or regenerate.
