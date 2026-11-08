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

SKIPUNZIP=0

fail() { ui_print "! $1"; rm -rf "$MODPATH/system"; abort "! Nothing was installed."; }

# patch_words FILE "OFF:OLD:NEW OFF:OLD:NEW ..."   (hex bytes, little-endian as stored)
patch_words() {
  f="$1"; shift
  for spec in $*; do
    off=$((${spec%%:*})); rest=${spec#*:}; old=${rest%%:*}; new=${rest#*:}
    have=$(dd if="$f" bs=1 skip=$off count=$(( ${#old} / 2 )) 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ "$have" = "$old" ] || fail "Unexpected bytes at offset $off in $(basename $f): got '$have', expected '$old'"
    printf "$(echo "$new" | sed 's/../\\x&/g')" | dd of="$f" bs=1 seek=$off count=$(( ${#new} / 2 )) conv=notrunc 2>/dev/null || fail "write failed at $off"
  done
}

do_patch() {  # NAME SRC DST STOCK_SHA PATCHED_SHA SPECS
  name=$1; src=$2; dst=$3; stock=$4; expect=$5; specs=$6
  ui_print "- $name: reading $src"
  [ -f "$src" ] || fail "$src not found"
  sum=$(sha256sum "$src" | cut -d' ' -f1); ui_print "  SHA-256: $sum"
  case "$sum" in
    $stock) ;;
    $expect) fail "$src is already patched. An older version of this module is probably still active: remove it, reboot, then reinstall." ;;
    *) fail "Unknown $name build. Only FiiO M33 R2R firmware 1.0.2 is supported. Please open an issue with your firmware version and this hash." ;;
  esac
  mkdir -p "$(dirname "$dst")"; cp -f "$src" "$dst" || fail "copy failed"
  patch_words "$dst" "$specs"
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
  a0203d703185ea30bf048887fc22b3037acf148d13f23f7038f8152a77ddd191 \
  "0xd0:4097010000000000:4897010000000000 0xd8:4097010000000000:4897010000000000 0x16574:9f010071:6c8e0a34 0x165b4:e0079f1a:20008052 0x1adf4:09011d39:1f2003d5 0x2b740:0000000000000000:e0031f2aa3abff17"

do_patch "audio.primary.bengal.so" /vendor/lib64/hw/audio.primary.bengal.so "$MODPATH/system/vendor/lib64/hw/audio.primary.bengal.so" \
  855df110b8d7d2b5b0d01354d78bec6a0b9cc9933d1a7661c17ae49587bbe6d2 \
  d16c987bceea3d184cb19c0f9e25de5c89dcc50c10c73817dc56d1615997b3ac \
  "0x53838:89f241b9:89da42b9"

set_perm_recursive "$MODPATH" 0 0 0755 0644
ui_print "- Done. Reboot to activate. Disable or remove this module in Magisk to revert."
