#!/usr/bin/env bash
# Regression suite for the FiiO M33 R2R A/V sync fix. Drives the probe app over adb through the
# scenario behind each patch and applies the pass criteria in tools/checks.ts.
#
#   tools/regression.sh [LABEL]        e.g. tools/regression.sh os   or   nos
#
# Run it once per output mode (Settings > Audio > PCM OUT MODE). Takes about seven minutes.
# Requires: adb on PATH (or ADB=...), bun, the probe installed (adb install -r probe/tsprobe.apk).
# Exit status is 0 only if every check passed. Scrubbed TSPROBE logs, HAL log excerpts and the
# thread dumps are written to OUT (default: regression-<label>-<date>/).
#
# Checks (the patch each one guards):
#   pause cycles 48k / 44.1k  queued_ms and head_minus_ts_ms constant across cycles   (patches 1, 4)
#   new track every 6 s       head_minus_ts_ms identical on every track               (patch 2)
#   rate switches             thread write latency flat over ten 48k/44.1k switches   (patch 4)
#   timestamp rate            AudioFlinger timestamp rate within 0.99..1.03            (patch 3)
#   log scan                  no 'goto create retrack', 'no more data to write',
#                             'Insufficient audio processing efficiency' anywhere      (1, 2, 4)
set -u
ADB=${ADB:-adb}
HERE=$(cd "$(dirname "$0")" && pwd)
command -v bun >/dev/null || { echo "bun is required (https://bun.sh)"; exit 2; }
LABEL=${1:-run}
OUT=${OUT:-regression-$LABEL-$(date +%Y%m%d-%H%M%S)}
PROBE=com.test.tsprobe/.MainActivity
TOL_MS=5
mkdir -p "$OUT"
check() { bun run "$HERE/checks.ts" "$@"; }
result() { # NAME "PASS|FAIL detail"
  printf '%-28s %s\n' "$1" "$2" | tee -a "$OUT/summary.txt"
}
probe() { $ADB shell am start -W -n $PROBE "$@" >/dev/null; }
thread_dump() { $ADB shell dumpsys media.audio_flinger | check threaddump; }
scrub() { sed -E 's/^[0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ //' | grep -E 'TSPROBE'; }
# appends the HAL/framework lines of interest since the last clear to hal.log, then clears logcat
collect_hal() {
  $ADB shell logcat -d -v threadtime | grep -E "sample_rate change|no more data|Insufficient|retrack|fill zero" \
    | sed -E 's/^[0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ //' >> "$OUT/hal.log"
  $ADB shell logcat -c
}

: > "$OUT/hal.log"
$ADB shell logcat -c
echo "== $LABEL: $(date)" | tee "$OUT/summary.txt"
$ADB shell getprop ro.build.fingerprint > "$OUT/fingerprint.txt"
$ADB shell sha256sum /system/lib64/libaudioclient.so /vendor/lib64/libfiioaudio.so /vendor/lib64/hw/audio.primary.bengal.so | tee "$OUT/hashes.txt"

# ---- pause/resume cycles (patches 1 and 4) --------------------------------------------
for rate in 48000 44100; do
  collect_hal
  probe --ei rate $rate --ei enc 2 --ei bufms 500 --ei secs 75 --ei cyclems 12000; sleep 78
  $ADB shell logcat -d -v threadtime -s TSPROBE | scrub > "$OUT/pause_cycles_${rate}.log"
  result "pause cycles $rate" "$(check pause "$OUT/pause_cycles_${rate}.log" $TOL_MS)"
done

# ---- new track every 6 s (patch 2) -----------------------------------------------------
collect_hal
probe --ei rate 48000 --ei enc 2 --ei bufms 500 --ei secs 60 --ei newtrackms 6000; sleep 63
$ADB shell logcat -d -v threadtime -s TSPROBE | scrub > "$OUT/new_track_48000.log"
result "new track every 6 s" "$(check track "$OUT/new_track_48000.log" $TOL_MS)"

# ---- rate switches (patch 4) and timestamp rate (patch 3) ------------------------------
collect_hal
: > "$OUT/rate_switches.txt"
for rate in 48000 44100 48000 44100 48000 44100 48000 44100 48000 44100; do
  probe --ei rate $rate --ei enc 2 --ei bufms 500 --ei secs 10; sleep 8
  { echo "run rate=$rate"; thread_dump; } >> "$OUT/rate_switches.txt"; sleep 5
done
$ADB shell logcat -d -v threadtime -s TSPROBE | scrub > "$OUT/rate_switches_probe.log"
collect_hal
result "rate switches" "$(check switch "$OUT/rate_switches.txt" $TOL_MS)"
result "timestamp rate" "$(check tsrate "$OUT/rate_switches.txt")"

# ---- log scan over the whole suite (patches 1, 2, 4) -----------------------------------
result "log scan" "$(check logscan "$OUT/hal.log")"

pass=$(grep -cE ' PASS ' "$OUT/summary.txt"); fail=$(grep -cE ' FAIL ' "$OUT/summary.txt")
echo "== $pass passed, $fail failed." | tee -a "$OUT/summary.txt"
echo "Output in $OUT"
[ "$fail" = 0 ]
