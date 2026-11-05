#!/usr/bin/env bash
# Builds the signed-release APK and refuses to produce one that is missing the
# Rust native library.
#
# Why this script exists: the Rust library carries the QRTR modem bus. Cargokit
# fails *soft* when it cannot build it — it prints "rustup not found in PATH"
# and the Gradle build happily continues, producing an APK with no
# librust_lib_nlpa2.so. Such an APK installs and runs, and only fails later at
# runtime with "dlopen failed: library ... not found" the moment a QRTR or
# SE HAL reader is used. Every release before this script was affected.
#
# Prerequisites:
#   - a Rust toolchain with the aarch64-linux-android target
#     (rustup toolchain install stable-x86_64-pc-windows-gnu \
#          --profile minimal --target aarch64-linux-android)
#   - the Android SDK/NDK (ANDROID_HOME)
#   - a JDK 17 (JAVA_HOME)
#
# Environment overrides:
#   RUSTUP_HOME, CARGO_HOME, RUSTUP_TOOLCHAIN, JAVA_HOME, ANDROID_HOME
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${JAVA_HOME:?JAVA_HOME must point at a JDK 17}"
: "${ANDROID_HOME:?ANDROID_HOME must point at the Android SDK}"
: "${RUSTUP_HOME:?RUSTUP_HOME must point at the rustup home}"
: "${CARGO_HOME:?CARGO_HOME must point at the cargo home}"
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable-x86_64-pc-windows-gnu}"
export PATH="$CARGO_HOME/bin:$PATH"

FLUTTER="${FLUTTER:-flutter}"
APK_OUT="build/app/outputs/flutter-apk/app-m-release.apk"
RUST_LIB="librust_lib_nlpa2.so"

# This project publishes its own feed; upstream's default would advertise
# upstream releases under a different package name.
UPDATE_FEED_URL="${UPDATE_FEED_URL:-https://raw.githubusercontent.com/MIY-Y/eUICC-Nexus/main/update_feed.json}"

# The name shown in the update dialog and the window title.
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-eUICC-Nexus}"

echo "==> toolchain"
rustup --version
rustc --version
cargo --version
rustup target list --installed | grep -q 'aarch64-linux-android' \
  || { echo "aarch64-linux-android target missing: rustup target add aarch64-linux-android --toolchain $RUSTUP_TOOLCHAIN" >&2; exit 1; }

echo "==> building"
# APP_VARIANT must be the channel name the update feed is published under
# ("multi"), not the flavor directory name ("m"): AppSettings.variant returns
# this value verbatim, and the feed is selected by channel.
"$FLUTTER" build apk --release --no-tree-shake-icons --flavor m \
  --dart-define=APP_VARIANT=multi --dart-define=APP_UPDATE_FEED_URL="$UPDATE_FEED_URL" \
  --dart-define=APP_DISPLAY_NAME="$APP_DISPLAY_NAME" \
  --target-platform android-arm64 --no-pub

echo "==> verifying native payload"
if [ ! -f "$APK_OUT" ]; then
  echo "APK not found at $APK_OUT" >&2
  exit 1
fi

# An APK is a zip; GNU tar cannot read one, so pick whichever reader exists.
list_apk() {
  if command -v unzip >/dev/null 2>&1; then
    unzip -Z1 "$APK_OUT"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import sys,zipfile;print('\n'.join(zipfile.ZipFile(sys.argv[1]).namelist()))" "$APK_OUT"
  else
    tar -tf "$APK_OUT"
  fi
}

# The listing is captured first: piping it straight into `grep -q` would let
# grep exit early, hand the reader a SIGPIPE, and make `set -o pipefail` report
# the whole pipeline as failed even though the entry was found.
apk_entries="$(list_apk || true)"
case "$apk_entries" in
  *"lib/arm64-v8a/$RUST_LIB"*) found=1 ;;
  *) found=0 ;;
esac

if [ "$found" -ne 1 ]; then
  cat >&2 <<EOF

FAILED: the built APK does not contain lib/arm64-v8a/$RUST_LIB.

The Rust library was not compiled, so the QRTR and SE HAL readers cannot work.
This build must not be released. Check that the Rust toolchain is on PATH and
that its aarch64-linux-android target is installed, then build again.
EOF
  exit 1
fi

echo "OK: $APK_OUT contains lib/arm64-v8a/$RUST_LIB"
