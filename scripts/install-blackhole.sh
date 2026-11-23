#!/usr/bin/env bash
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  cat <<'EOF'
Homebrew is not installed.
Install it from https://brew.sh or download BlackHole 2ch manually:
https://github.com/ExistentialAudio/BlackHole/releases
EOF
  exit 1
fi

cat <<'EOF'
This installs BlackHole 2ch, a local loopback audio device used by MiVoice's
WeChat Input Method mode. It is a HAL plugin, not a kernel extension. macOS
will ask for your administrator password, and Core Audio will restart briefly.
EOF

read -r -p "Continue? [y/N] " answer
case "$answer" in
  y|Y) ;;
  *) echo "Cancelled."; exit 0 ;;
esac

brew install --cask blackhole-2ch
echo
echo "BlackHole installed. Open MiVoice settings and select it as the virtual microphone."
