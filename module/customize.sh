#!/system/bin/sh
# Magisk module installer script (runs inside Magisk's busybox environment).
# Copies the device's OWN libraries, verifies they are known stock FiiO M33 R2R
# builds, applies a handful of byte patches, verifies the results, and installs
# the patched copies systemlessly. Nothing is installed on any failure.
#
# Patch 1: /system/lib64/libaudioclient.so  (AudioTrack::config_audio_params)
#   skip FiiO's forced server-track recreation on start() when the track's
#   rate/format differ from the output.  1 instruction.
# Patch 2: /vendor/lib64/libfiioaudio.so  (start_config_params / processAudioConfigParams)
#   only reset FiiO's processing ring buffers when the parameters actually
#   changed; otherwise return "unchanged" (0).  4 instructions, an 8-byte stub
#   in the executable segment's padding, and +8 on that segment's size.
# Patch 3: /vendor/lib64/hw/audio.primary.bengal.so  (StreamOutPrimary::GetFramesWritten)
#   compute the presentation position with the HAL's own input frame size
#   instead of the client's; fixes the position running at 2x in NOS mode,
#   where the framework thread is 16-bit but the HAL writes 32-bit.  1 instruction.
# Patch 4: /vendor/lib64/libfiioaudio.so  (processAudioEvent)
#   when the processing thread has not produced output yet (happens on every
#   hardware sample-rate switch), wait up to 10 x 2 ms for it instead of
#   returning 0, which made the HAL report the buffer as written without
#   writing it and grew the real latency by one buffer (20 ms) per switch.
#   1 branch retargeted, an 18-instruction stub in the padding, segment +0x48.

# Not used in this script: Magisk reads SKIPUNZIP from customize.sh to decide whether to
# extract the module files itself (https://topjohnwu.github.io/Magisk/guides.html#customization).
# shellcheck disable=SC2034
SKIPUNZIP=0

fail() { ui_print "! $1"; rm -rf "$MODPATH/system"; abort "! Nothing was installed."; }

# patch_words FILE "OFF:OLD:NEW OFF:OLD:NEW ..."   (hex bytes, little-endian as stored)
patch_words() {
  f="$1"; shift
  for spec in $1; do
    off=$((${spec%%:*})); rest=${spec#*:}; old=${rest%%:*}; new=${rest#*:}
    have=$(dd if="$f" bs=1 skip=$off count=$(( ${#old} / 2 )) 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
    [ "$have" = "$old" ] || fail "Unexpected bytes at offset $off in $(basename "$f"): got '$have', expected '$old'"
    # The format string is the data here: \xNN escapes built from the spec's hex digits, so it
    # cannot contain a % directive. printf '%b' would decode \xNN on a different code path from
    # the one validated on the device, and POSIX defines \xNN for neither
    # (https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html).
    # shellcheck disable=SC2059
    printf "$(echo "$new" | sed 's/../\\x&/g')" | dd of="$f" bs=1 seek=$off count=$(( ${#new} / 2 )) conv=notrunc 2>/dev/null || fail "write failed at $off"
  done
}

# unpatch_words FILE SPECS : apply SPECS in reverse (NEW -> OLD) to recover the stock bytes
unpatch_words() {
  f="$1"; shift; inv=""
  for spec in $1; do
    off=${spec%%:*}; rest=${spec#*:}; old=${rest%%:*}; new=${rest#*:}
    inv="$inv $off:$new:$old"
  done
  patch_words "$f" "$inv"
}

do_patch() {  # NAME SRC DST STOCK_SHA PATCHED_SHA SPECS [PREV_SHA PREV_SPECS]
  name=$1; src=$2; dst=$3; stock=$4; expect=$5; specs=$6; prev=$7; prevspecs=$8
  ui_print "- $name: reading $src"
  [ -f "$src" ] || fail "$src not found"
  sum=$(sha256sum "$src" | cut -d' ' -f1); ui_print "  SHA-256: $sum"
  mkdir -p "$(dirname "$dst")"; cp -f "$src" "$dst" || fail "copy failed"
  case "$sum" in
    "$stock") patch_words "$dst" "$specs" ;;
    "$expect") ui_print "  already at this module's version, keeping" ;;
    "$prev") ui_print "  previous module version found, upgrading"
           unpatch_words "$dst" "$prevspecs"
           [ "$(sha256sum "$dst" | cut -d' ' -f1)" = "$stock" ] || fail "$name: could not recover stock bytes"
           patch_words "$dst" "$specs" ;;
    *) fail "Unknown $name build. Only FiiO M33 R2R firmware 1.0.2 is supported. If an older version of this module is active, disable it and reboot first. Otherwise open an issue with your firmware version and this hash." ;;
  esac
  got=$(sha256sum "$dst" | cut -d' ' -f1)
  [ "$got" = "$expect" ] || fail "$name: patched hash mismatch ($got)"
  ui_print "  patched OK: $got"
}

# ---- firmware 1.0.2 (build FiiO04281702 / eng.FiiO.20260428) ----
do_patch "libaudioclient.so" /system/lib64/libaudioclient.so "$MODPATH/system/lib64/libaudioclient.so" \
  221084582f2ed50fca14a04918e301e530b63e0343b94028a7c5cc48623532d7 \
  fce12ea84fce63aa12f6b593d6a87dcdc2797fe5e0e5520861c87247f1199173 \
  "0xa0ed8:81000054:13000014"

do_patch "libfiioaudio.so" /vendor/lib64/libfiioaudio.so "$MODPATH/system/vendor/lib64/libfiioaudio.so" \
  2fbb367bfcff06e0fd1b2d94ad994edacee27280792d5b74d202d8a50d59d563 \
  286523a244093ee48b3e3ad80904488cc1943e189e3bf6d8eb4be3d18d1c1cac \
  "0xd0:40970100:90970100 0xd8:40970100:90970100 0x16574:9f010071:6c8e0a34 0x165b4:e0079f1a:20008052 0x1adf4:09011d39:1f2003d5 0x1b688:a8010034:30400014 0x2b740:0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000:e0031f2aa3abff17400080520040a3723f03006b800100545b01805200fa805260feff97007200f000441d91e103182a6cfeff97f703002a37faf7357b070071e1feff5468325d39a8f9f734c0bfff17" \
  a0203d703185ea30bf048887fc22b3037acf148d13f23f7038f8152a77ddd191 \
  "0xd0:4097010000000000:4897010000000000 0xd8:4097010000000000:4897010000000000 0x16574:9f010071:6c8e0a34 0x165b4:e0079f1a:20008052 0x1adf4:09011d39:1f2003d5 0x2b740:0000000000000000:e0031f2aa3abff17"

do_patch "audio.primary.bengal.so" /vendor/lib64/hw/audio.primary.bengal.so "$MODPATH/system/vendor/lib64/hw/audio.primary.bengal.so" \
  855df110b8d7d2b5b0d01354d78bec6a0b9cc9933d1a7661c17ae49587bbe6d2 \
  d16c987bceea3d184cb19c0f9e25de5c89dcc50c10c73817dc56d1615997b3ac \
  "0x53838:89f241b9:89da42b9"

set_perm_recursive "$MODPATH" 0 0 0755 0644
ui_print "- Done. Reboot to activate. Disable or remove this module in Magisk to revert."
