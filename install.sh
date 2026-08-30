#!/bin/sh
# Installs the Passthru HAL driver into the system plug-in directory and
# restarts coreaudiod. Requires sudo.
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "usage: sudo ./install.sh"
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/driver/build/Passthru.driver"
HAL="/Library/Audio/Plug-Ins/HAL"

if [ ! -d "$SRC" ]; then
  echo "ERROR: $SRC not built. Run:"
  echo "  cmake -B driver/build -S driver && cmake --build driver/build"
  exit 1
fi

# Ad-hoc sign; unsigned also reportedly loads, this removes one variable.
codesign --force --deep -s - "$SRC"

mkdir -p "$HAL"
rm -rf "$HAL/Passthru.driver"
cp -R "$SRC" "$HAL/"
chown -R root:wheel "$HAL/Passthru.driver"
echo "installed: $HAL/Passthru.driver"

echo "restarting coreaudiod (killall -9)..."
killall -9 coreaudiod 2>/dev/null || true
sleep 3

if system_profiler SPAudioDataType 2>/dev/null | grep -q "Passthru"; then
  echo "OK: 'Passthru' enumerated after killall (no reboot needed)"
else
  echo "NOT LISTED after killall. Try a reboot before concluding failure;"
  echo "check Console.app for coreaudiod / Core-Audio-Driver-Service errors."
fi
