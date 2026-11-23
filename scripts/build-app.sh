#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${CONFIG:-release}"
IDENTITY="${CODESIGN_IDENTITY:--}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found. Install Xcode or the Command Line Tools first." >&2
  exit 1
fi

ARCH_ARGS=""
for arch in ${ARCHS:-}; do
  ARCH_ARGS="$ARCH_ARGS --arch $arch"
done

echo "==> Building ($CONFIG ${ARCHS:-native})"
swift build -c "$CONFIG" --product MiVoice $ARCH_ARGS

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path $ARCH_ARGS)"
BIN="$BIN_DIR/MiVoice"
if [ ! -x "$BIN" ]; then
  echo "Build output missing: $BIN" >&2
  exit 1
fi

APP="$ROOT/dist/MiVoice.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MiVoice"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Packaging/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
cp "$ROOT/Packaging/MenuBarIcon@2x.png" "$APP/Contents/Resources/MenuBarIcon@2x.png"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "==> Built $APP"
du -sh "$APP"

if [ "${INSTALL:-0}" = "1" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/MiVoice.app"
  cp -R "$APP" "$HOME/Applications/MiVoice.app"
  echo "==> Installed $HOME/Applications/MiVoice.app"
  echo "    Open it from Finder, or run: open \"$HOME/Applications/MiVoice.app\""
fi
