#!/bin/sh
# Removes the Passthru HAL driver and restarts coreaudiod. Requires sudo.
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "usage: sudo ./uninstall.sh"
  exit 1
fi

HAL="/Library/Audio/Plug-Ins/HAL/Passthru.driver"

if [ -d "$HAL" ]; then
  rm -rf "$HAL"
  echo "removed: $HAL"
else
  echo "not installed: $HAL"
fi

echo "restarting coreaudiod (killall -9)..."
killall -9 coreaudiod 2>/dev/null || true
echo "done"
