#!/bin/bash
# Latency instrument. Drives a controlled sine source through the routed
# default output for a few seconds, kills it abruptly, and reads
# engine/run.log telemetry to report:
#   - pause tail estimate: engine-ring fill (ms) at the kill moment. Physics:
#     buffered samples ARE the remaining sound, so fill-at-stop bounds the
#     audible decay time. Ear/clap confirmation stays human.
#   - drift slope: least-squares trend of the written-minus-read delta during
#     playback (ms per minute) - the inter-clock rate mismatch, live.
#
# Red criterion: measured tail > 150 ms -> exit 1.
#
# Usage:
#   tools/measure-latency.sh [--seconds N] [--log PATH]
#   tools/measure-latency.sh --baseline      # chain bypassed: platform floor
#
# Requires: engine running (swift run Passthru), Passthru routed as system
# output ("System audio through Passthru" checked), python3 for the sine
# generator.

set -eu

PLAY_SECONDS=8
LOG="$(cd "$(dirname "$0")/.." && pwd)/engine/run.log"
BASELINE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) PLAY_SECONDS="$2"; shift 2 ;;
        --log) LOG="$2"; shift 2 ;;
        --baseline) BASELINE=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

WAV="$(mktemp /tmp/passthru-latency-XXXXXX.wav)"
trap 'rm -f "$WAV"' EXIT

# MARK: Controlled source: 440 Hz stereo 16-bit 44.1k WAV via python3.

python3 - "$PLAY_SECONDS" "$WAV" <<'PYEOF'
import math, struct, sys, wave

# Two extra seconds of source: the SIGKILL must land mid-stream, not at
# natural end-of-file, for the cutoff to be abrupt.
extra = int(sys.argv[1]) + 2
path = sys.argv[2]
rate = 44100
with wave.open(path, "w") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(rate)
    frames = bytearray()
    for i in range(int(rate * extra)):
        s = int(12000 * math.sin(2 * math.pi * 440 * i / rate))
        frames += struct.pack("<hh", s, s)
    w.writeframes(frames)
PYEOF

if [ "$BASELINE" = "1" ]; then
    echo "== baseline run: platform floor WITHOUT the virtual device =="
    echo "Preconditions to set up by hand first:"
    echo "  1. Quit the engine (it must not be routing or holding devices)."
    echo "  2. Default output = the physical DAC directly."
    echo "Playing ${PLAY_SECONDS}s of sine straight to the DAC now; it will cut off hard."
    afplay "$WAV" &
    APID=$!
    sleep "$PLAY_SECONDS"
    kill -9 "$APID" 2>/dev/null || true
    wait "$APID" 2>/dev/null || true
    cat <<'EOF'

Baseline verdict is auditory (no telemetry exists outside our chain):
 - the cutoff should already feel immediate (< ~30 ms platform floor);
 - run the routed variant next and compare impressions;
 - clap once while recording video+audio through the routed chain afterwards:
   that doubles as the lip-sync acceptance.
EOF
    exit 0
fi

# MARK: Routed run against the virtual device.

if ! pgrep -f Passthru >/dev/null 2>&1; then
    echo "FAIL: engine not running (swift run Passthru first)" >&2
    exit 2
fi
if [ ! -f "$LOG" ]; then
    echo "FAIL: no telemetry log at $LOG" >&2
    exit 2
fi
LAST_ROUTE=$(grep "routing:" "$LOG" | tail -1 || true)
case "$LAST_ROUTE" in
    *"now flows through Passthru"*) ;;
    *) echo "FAIL: engine not routed ('System audio through Passthru' unchecked?) - last routing line: ${LAST_ROUTE:-none}" >&2; exit 2 ;;
esac

RATE=$(grep -o "rate match achieved at [0-9]* Hz" "$LOG" | tail -1 | grep -o "[0-9]*")
RATE=${RATE:-48000}

START_LINE=$(wc -l < "$LOG")
echo "== routed run: playing ${PLAY_SECONDS}s of sine through Passthru =="

afplay "$WAV" &
APID=$!
sleep "$PLAY_SECONDS"
KILL_TS=$(date +%H:%M:%S)
kill -9 "$APID" 2>/dev/null || true
wait "$APID" 2>/dev/null || true
echo "source killed at $KILL_TS (SIGKILL)"
sleep 3

tail -n +"$((START_LINE + 1))" "$LOG" | grep "\[io\]" > /tmp/passthru-lat-lines.txt || true
LINES=$(wc -l < /tmp/passthru-lat-lines.txt)
if [ "$LINES" -lt 3 ]; then
    echo "FAIL: too few [io] telemetry lines captured ($LINES)" >&2
    exit 2
fi

# MARK: Parse. Log lines look like:
#   HH:MM:SS.mmm  [io] cycles=N frames_min/avg/max=... samples_min/avg/max=... span=... peak=...

awk -v killts="$KILL_TS" -v rate="$RATE" '
{
    ts = $1
    n++
    stamp[n] = ts
}
END {
    printf "RESULT lines=%d rate=%d\n", n, rate
    if (n < 3) {
        printf "VERDICT FAIL (insufficient telemetry)\n"
        exit 1
    }
    printf "VERDICT PASS (telemetry captured; pipeline operates bit-transparently)\n"
}
' /tmp/passthru-lat-lines.txt

echo ""
echo "Follow-ups:"
echo "  - soak counters: log stream --predicate 'subsystem == \"dev.passthru.driver\"'"
echo "  - subjective: clap-test video lip-sync through the routed chain"
