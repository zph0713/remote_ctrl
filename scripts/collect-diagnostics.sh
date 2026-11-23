#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."

echo "== MiVoice diagnostics =="
date
echo
echo "== macOS =="
sw_vers
uname -m
echo
echo "== App signature =="
APP="${1:-$HOME/Applications/MiVoice.app}"
if [ -d "$APP" ]; then
  codesign -dv "$APP" 2>&1 | sed -n '1,12p'
  echo "path: $APP"
else
  echo "not installed at $APP"
fi
echo
echo "== Process =="
pgrep -fl MiVoice || echo "not running"
echo
echo "== RC003 HID (VID 2717 / PID 32B8) =="
ioreg -r -c IOHIDDevice -l 2>/dev/null | grep -iE '"(VendorID|ProductID|Product|PrimaryUsage)"' | \
  grep -iE '2717|32B8|MI RC|Xiaomi|Remote' || echo "no matching HID device"
echo
echo "== Bluetooth (paired remotes) =="
system_profiler SPBluetoothDataType 2>/dev/null | grep -iE 'MI RC|Xiaomi|Remote|Connected|Not Connected' | head -30
echo
echo "== Recent MiVoice logs =="
log show --last 10m --style compact --predicate 'subsystem == "app.mivoice"' 2>/dev/null | tail -80
echo
echo "== Network connections (should be empty) =="
PID="$(pgrep -x MiVoice | head -1 || true)"
if [ -n "${PID:-}" ]; then
  lsof -nP -i -p "$PID" 2>/dev/null || echo "no network sockets"
else
  echo "MiVoice not running"
fi
