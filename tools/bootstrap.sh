#!/usr/bin/env bash
#
# Set this repo up on a Mac that has never seen it.
#
#   tools/bootstrap.sh                 # ask for the Garmin login when needed
#   GARMIN_USERNAME=... GARMIN_PASSWORD=... tools/bootstrap.sh    # unattended
#
# Idempotent: every step checks before it acts, so re-running after a failure
# picks up where it stopped rather than reinstalling what is already there.
#
# It deliberately does NOT create developer_key. That file is the app's identity
# in the Connect IQ store, and a fresh one is a different app: see the note this
# prints at the end. Carrying it across is a decision, not a setup step.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The simulator version is the whole reason this script exists. 9.2.0 segfaults
# on macOS 26 the moment an app draws, so `make sim` looks for a 9.1.x beside
# whatever the compiler uses. Keep in step with SIM_SDK in the Makefile.
SIM_SDK_VERSION="9.1.0"

step() { printf '\n\033[1m>> %s\033[0m\n' "$1"; }
ok()   { printf '   \033[32mok\033[0m  %s\n' "$1"; }
warn() { printf '   \033[33m!!\033[0m  %s\n' "$1"; }

[ "$(uname -s)" = "Darwin" ] || {
    echo "!! macOS only. On Linux the SDK and its simulator exist but none of" >&2
    echo "   the Homebrew lines below apply; see docs/DEVELOPMENT.md." >&2
    exit 1
}

step "Homebrew"
if command -v brew >/dev/null 2>&1; then
    ok "$(brew --version | head -1)"
else
    echo "!! not installed. https://brew.sh, then run this again." >&2
    exit 1
fi

step "Toolchain"
# temurin@21 is a .pkg and asks for sudo; the casks do not. Installing them
# separately keeps the password prompt in one predictable place.
for cask in connectiq connectiq-sdk-manager temurin@21; do
    if brew list --cask "$cask" >/dev/null 2>&1; then
        ok "$cask"
    else
        step "installing $cask"
        brew install --cask "$cask"
    fi
done

if brew list libmtp >/dev/null 2>&1; then
    ok "libmtp"
else
    step "installing libmtp (make watch, side-loading over USB)"
    brew install libmtp
fi

step "SDK manager CLI"
if command -v connect-iq-sdk-manager >/dev/null 2>&1; then
    ok "$(connect-iq-sdk-manager version 2>/dev/null | head -1)"
else
    curl -sSf https://raw.githubusercontent.com/lindell/connect-iq-sdk-manager/master/install.sh | sh
    command -v connect-iq-sdk-manager >/dev/null 2>&1 || {
        echo "!! installed but not on PATH. Add ~/.local/bin to PATH." >&2
        exit 1
    }
fi

step "Garmin account"
# Everything past here is gated on an account, and the gate is not ours to open.
# With GARMIN_USERNAME/GARMIN_PASSWORD set this is unattended, which is what CI
# does; without them it opens the SSO flow in a browser.
if connect-iq-sdk-manager sdk list >/dev/null 2>&1; then
    ok "already logged in"
else
    connect-iq-sdk-manager login
fi
connect-iq-sdk-manager agreement accept

step "SDKs"
# Two of them, on purpose: the newest to compile with, $SIM_SDK_VERSION to
# simulate with.
if compgen -G "$HOME/.Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-${SIM_SDK_VERSION%.*}.*" >/dev/null; then
    ok "$SIM_SDK_VERSION present (the one make sim uses)"
else
    step "downloading SDK $SIM_SDK_VERSION for the simulator"
    connect-iq-sdk-manager sdk download "$SIM_SDK_VERSION"
fi

step "Device definitions"
DEVICE_DIR="$HOME/Library/Application Support/Garmin/ConnectIQ/Devices"
if [ -d "$DEVICE_DIR" ] && [ -n "$(ls -A "$DEVICE_DIR" 2>/dev/null)" ]; then
    ok "$(ls "$DEVICE_DIR" | wc -l | tr -d ' ') installed"
else
    connect-iq-sdk-manager device download --manifest=manifest.xml
fi

step "Packer"
python3 --version
python3 -c "import PIL" 2>/dev/null \
    && ok "pillow" \
    || warn "no pillow: 10 preview tests will skip. pip install pillow"

step "Signing key"
if [ -f developer_key ]; then
    ok "present"
else
    cat <<'EOF'
   !! developer_key is missing, and this script will not create one.

      The Connect IQ store pins a published app to the key that signed its
      first upload. Generating a new key here gives you a working build that
      can never update the listing.

      Coming from another machine you already build on:
          scp other-mac:path/to/garmin-offline-maps/developer_key .

      Starting fresh, and never publishing under the existing app id:
          make key
EOF
fi

step "make doctor"
make doctor

cat <<'EOF'

Two things no script can carry for you:

  developer_key    the store identity, above. Not in git, not recoverable.
  your GPG key     commits here are signed. `gpg --list-secret-keys` on the
                   machine that has it, export, import here, and set
                   user.signingkey to match.

Then: make test && make build && make sim
EOF
