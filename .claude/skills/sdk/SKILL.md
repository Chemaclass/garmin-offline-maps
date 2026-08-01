---
name: sdk
description: Set up, locate or repair the Connect IQ toolchain, then compile/run the watch app. Use when monkeyc is missing, `make build`/`make sim`/`make package` fails before compiling, device definitions for venu3/venu3s are missing, or the user asks to install the Garmin SDK, open the simulator, or side-load to the watch.
---

# Connect IQ toolchain

## 1. Find out what is actually missing

```bash
which monkeyc monkeydo connectiq
java -version 2>&1 | head -2
ls ~/Library/Application\ Support/Garmin/ConnectIQ/Devices/ 2>/dev/null
```

Three separate things must exist, and they fail with similar-looking errors:

| Missing | Symptom |
|---|---|
| SDK binaries | `make: monkeyc: No such file or directory` |
| Java runtime | `Unable to locate a Java Runtime` |
| Device definitions | `monkeyc` runs, then errors on `-d venu3` |

## 2. Install what is missing

```bash
brew install --cask connectiq              # SDK: monkeyc, monkeydo, ConnectIQ.app -- no Garmin login
brew install --cask temurin                # JDK 21, matching CI, if java is absent
brew install --cask connectiq-sdk-manager  # GUI, free Garmin account -- for device definitions
```

Device definitions are the part that needs an account. The SDK download does
not carry them; `SdkManager.app` fetches them into
`~/Library/Application Support/Garmin/ConnectIQ/Devices/`. Headless alternative,
the same one CI uses (`.github/workflows/ci.yml`):

```bash
curl -sSf https://raw.githubusercontent.com/lindell/connect-iq-sdk-manager-cli/master/install.sh | sh
connect-iq-sdk-manager login                              # GARMIN_USERNAME / GARMIN_PASSWORD
connect-iq-sdk-manager device download --manifest=manifest.xml
```

Ask the user before installing anything — these are multi-hundred-MB downloads
and the SDK Manager needs their Garmin credentials, which only they can enter.

## 3. Build without touching PATH

The Makefile takes the SDK location as a variable:

```bash
make build SDK_BIN="$(brew --prefix)/bin"
make build SDK_BIN=~/Library/Application\ Support/Garmin/ConnectIQ/Sdks/current/bin
```

## 4. Run it

```bash
make build DEVICE=venu3     # -> bin/offline-maps-venu3.prg
make build DEVICE=venu3s    # every product in manifest.xml, not just the default
make sim                    # launches the simulator, waits 6s, side-loads
make package                # -> bin/offline-maps.iq for the store
```

On the watch: plug in over USB, copy the `.prg` into `GARMIN/APPS/`, eject.

## Expect compile errors on the first build

Per the README's Status section, this Monkey C has never been through
`monkeyc`. The first real build is a bug-finding exercise, not a smoke test.
Fix each error on its merits and report them; do not restructure working logic
to silence a message. `developer_key` is the app's store identity — never
print, commit or regenerate it.
