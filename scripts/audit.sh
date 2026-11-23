#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "== 1. Network API scan (Sources only) =="
if grep -RInE 'URLSession|NSURLConnection|CFNetwork|import[[:space:]]+Network|import[[:space:]]+WebKit|NWConnection|http://|https://' Sources; then
  echo "FAIL: network-related code found in Sources" >&2
  exit 1
fi
echo "OK: no network APIs in Sources"

echo
echo "== 2. SwiftPM dependencies =="
if grep -nE '\.package\(' Package.swift; then
  echo "FAIL: external package dependency found" >&2
  exit 1
fi
echo "OK: no external SwiftPM dependencies"

echo
echo "== 3. App bundle =="
APP="${1:-dist/MiVoice.app}"
if [ ! -d "$APP" ]; then
  echo "No built app at $APP (run scripts/build-app.sh first)."
  exit 0
fi

du -sh "$APP"
echo
echo "-- signature --"
codesign -dv "$APP" 2>&1 | sed -n '1,14p'
echo
echo "-- linked libraries --"
otool -L "$APP/Contents/MacOS/MiVoice" | sed -n '1,40p'
