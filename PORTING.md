# Porting the fix to another firmware or device

This guide is for a person or an AI coding agent adapting this module to a FiiO M33 R2R
firmware other than 1.0.2, or to another FiiO Android DAP that shares FiiO's audio
framework patches. Every step is deterministic: you locate three code sites by symbol
and string anchors, confirm the exact stock instruction bytes, record the new hashes, and
add one entry per library to `module/customize.sh`. The installer refuses to install
anything whose hash or bytes do not match, so a mistake in this process produces an
"install nothing" result, not a bricked audio stack.

Firmware 1.0.2 values are given throughout as the reference. Expect offsets to move on
other builds; expect the instruction *patterns* to stay the same.

**Contents**

1. [Prerequisites and safety rules](#1-prerequisites-and-safety-rules)
2. [Pull the three libraries and hash them](#2-pull-the-three-libraries-and-hash-them)
3. [The three patches](#3-the-three-patches): [3.1 libaudioclient](#31-libaudioclientso-skip-the-forced-audiotrack-recreation), [3.2 libfiioaudio](#32-libfiioaudioso-only-reset-the-processing-ring-buffers-when-parameters-change), [3.3 audio HAL](#33-audioprimarybengalso-hal-frame-size-in-the-presentation-position)
4. [Adding a firmware to customize.sh](#4-adding-a-firmware-to-customizesh)
5. [Verification](#5-verification)
6. [Pull request checklist](#6-pull-request-checklist)

**The whole job in one paragraph.** Pull the three libraries from the device and hash them
(section 2). In each, find one function by its exported symbol, confirm the stock
instruction pattern shown in section 3 at that site, and compute the replacement bytes
with the encoding formulas given there. Write the patched copies on the host and diff them
against stock to confirm only the intended bytes changed. Paste the resulting
`offset:old:new` specs and the two hashes per library into `module/customize.sh`
(section 4). Install on the device, reboot, run the probe in OS and NOS and check the pass
criteria (section 5), then open a PR with the checklist filled in (section 6). Budget a
few hours the first time.

---

## 1. Prerequisites and safety rules

You need:

- A device with an **unlocked bootloader** (`fastboot getvar unlocked` prints `yes`).
- **Magisk root** installed via a patched `init_boot` (these devices have an `init_boot`
  partition; Magisk patches that, not `boot`). Magisk 31+ has no root prompt: grant
  "Shell" in the Magisk app's Superuser tab so `adb shell su` works.
- `adb` and `fastboot` on the host, plus a disassembler: `objdump` from LLVM or binutils
  (`llvm-objdump -d` handles AArch64 ELF; the macOS Xcode `objdump` does too), or Ghidra.
- Python 3 for byte patching and hashing.

Rules, in order of how badly it goes if you break them:

1. **Back up the stock `init_boot` image for your exact firmware before flashing
   anything.** Extract it from the OTA zip's `payload.bin` with a payload dumper, record
   its SHA-256, and keep it off the device. It is the only rollback for a bad Magisk image.
2. **Flash only `init_boot` on the active slot.** Never flash `vbmeta`, `boot`,
   `vendor_boot`, `dtbo`, or anything else for this fix. Check `fastboot getvar current-slot`
   and flash `init_boot_a` or `init_boot_b` accordingly.
3. **Never read anything under `/sys/devices/platform/soc/soc:fiio_attr/`.** Reading some
   of FiiO's debug attributes there (`adc_debug_*`, `gpio_debug_*`, `uart_debug_*`,
   `fpga_*`) crashes the kernel and reboots the device. Do not `cat`, `find -exec cat`, or
   `grep -r` that directory.
4. **Never modify `/system` or `/vendor` directly.** All changes go through a Magisk
   module so disabling the module restores stock behaviour.
5. Do not include firmware images, extracted partitions, or any FiiO `.so` file in a pull
   request. The module patches the device's own copies at install time; the repository
   holds only offsets, bytes, and hashes.

---

## 2. Pull the three libraries and hash them

```
mkdir -p port/stock && cd port
adb pull /system/lib64/libaudioclient.so        stock/
adb pull /vendor/lib64/libfiioaudio.so          stock/
adb pull /vendor/lib64/hw/audio.primary.bengal.so stock/   # see note on the HAL name
shasum -a 256 stock/*
adb shell getprop ro.build.fingerprint
adb shell getprop ro.product.ota.package_name
```

Record the firmware version, the build fingerprint, and the three hashes. These go into
the `customize.sh` table and the README's supported-firmware table.

Note on the HAL name: `audio.primary.bengal.so` is Qualcomm's AudioReach HAL for the
Bengal/Khaje SoC in the M33 R2R. On another DAP, list `/vendor/lib64/hw/audio.primary.*.so`
and use whichever one `audioserver` loads (`adb shell dumpsys media.audio_flinger | head`
shows the loaded HAL module name). If the HAL is not AudioReach (`libar-pal.so` absent),
patch 3 does not apply as written; see section 3.3.

Also pull the disassembly once for reference:

```
mkdir -p asm
llvm-objdump -d --no-show-raw-insn -C stock/libaudioclient.so        > asm/libaudioclient.asm
llvm-objdump -d --no-show-raw-insn -C stock/libfiioaudio.so          > asm/libfiioaudio.asm
llvm-objdump -d --no-show-raw-insn -C stock/audio.primary.bengal.so  > asm/hal.asm
```

All three libraries have their dynamic symbols intact (not stripped of exports), so
`nm -D --defined-only <lib> | c++filt` lists the function names used below.

### Mapping virtual addresses to file offsets

Patches are applied at **file offsets**. For these libraries the first executable segment
has `p_offset == p_vaddr`, so the addresses `objdump` prints equal the file offsets. Do not
assume this on another build; verify with the program headers:

```python
import struct
d = open('stock/libfiioaudio.so','rb').read()
phoff = struct.unpack_from('<Q', d, 0x20)[0]; phentsize, phnum = struct.unpack_from('<HH', d, 0x36)
for i in range(phnum):
    t, f, off, va, pa, fsz, msz, al = struct.unpack_from('<IIQQQQQQ', d, phoff + i*phentsize)
    if t == 1: print(f'LOAD flags={f} off={off:#x} va={va:#x} filesz={fsz:#x} memsz={msz:#x}')
```

`file_offset = p_offset + (va - p_vaddr)` for the LOAD segment containing `va`.

---

## 3. The three patches

For each patch: what it fixes, how to find the site, what the stock bytes look like, and
what they become. Confirm every site in the disassembler before computing bytes. Never
patch on the strength of an offset copied from this document.

### 3.1 `libaudioclient.so`: skip the forced AudioTrack recreation

**Symptom fixed.** Audio leads video by a step that grows after every pause/resume. FiiO's
`AudioTrack::config_audio_params()` runs on every `start()`; when the track's sample rate or
format differs from the output thread's, it recreates the server track with
`createTrack_l()`, and the audio queued in the app buffer is lost from position tracking.

**Anchors.**

- Symbol: `android::AudioTrack::config_audio_params()` (exported; `nm -D` shows it).
- String: `%s:goto create retrack for sample rate or format not match`.
- Nearby string, same function: `%s:goto create retrack for p2d and sample rate isn't 176.4K`
  (that is a *different* branch; leave it alone).
- Log line at runtime: `AudioTrack: config_audio_params:goto create retrack for sample rate or format not match`.

**Find the site.**

1. `grep -n 'config_audio_params' asm/libaudioclient.asm` to get the function's range.
2. Inside it, find where the "sample rate or format not match" string is loaded: the
   string's file offset from `strings -t x -n 8 stock/libaudioclient.so | grep 'format not match'`,
   then the `adrp x2, 0xNN000` / `add x2, x2, #0xMMM` pair that forms that address before an
   `__android_log_print` call.
3. Walk **backwards** from that log call a few instructions. The stock pattern is:

```
tbnz   w26, #0x0, <skip>          ; p2d flag set -> skip entirely
cmp    w8,  w21                   ; mFormat vs output format
b.ne   <log_and_retrack>          ;  <-- PATCH THIS INSTRUCTION
ldr    w8,  [x19, #0x40]          ; mSampleRate
cmp    w8,  w20                   ; vs output sample rate
b.eq   <skip>                     ; both match -> skip
<log_and_retrack>:
adrp/add ... "goto create retrack for sample rate or format not match"
bl     __android_log_print
...
bl     android::AudioTrack::createTrack_l()
<skip>:
mov    w23, wzr
```

Register numbers may differ on another build; the shape (`cmp`, `b.ne`, `ldr`, `cmp`,
`b.eq`, log, `createTrack_l`) is what you match.

**Patch.** Replace the `b.ne <log_and_retrack>` with an unconditional `b <skip>`, where
`<skip>` is the instruction right after the `bl createTrack_l` (the `mov w23, wzr` in 1.0.2).

| | 1.0.2 offset | bytes (LE) | instruction |
|---|---|---|---|
| stock | `0xa0ed8` | `81 00 00 54` | `b.ne 0xa0ee8` |
| patched | `0xa0ed8` | `13 00 00 14` | `b 0xa0f24` |

Encode the new branch yourself: `b` is `0x14000000 | (((target - site) >> 2) & 0x3ffffff)`.
Confirm with `objdump` on the patched file that the site now reads `b <skip>` and that the
`ldr/cmp/b.eq` after it are untouched.

### 3.2 `libfiioaudio.so`: only reset the processing ring buffers when parameters change

**Symptom fixed.** Audio leads video by about 40 ms more with every newly created
AudioTrack (YouTube Shorts, playlist transitions), never recovering. On every
`createTrack`, FiiO's AudioFlinger pushes `sampling_rate` and `format` to the HAL; the HAL
calls `FiiOAudioConfigParams()`, and `start_config_params()` zeroes the input and output ring
buffers unconditionally, discarding queued audio. The chain then re-primes with two buffers
that AudioFlinger counts but the HAL never writes (HAL log `no more data to write`).

**Anchors.**

- Symbols (exported): `start_config_params(unsigned int, unsigned int, unsigned int, unsigned int*, unsigned int*, unsigned int*, unsigned int*)`,
  `processAudioConfigParams(...)` / `FiiOAudioConfigParams(...)`, `reset_player_and_pcm_cache()`.
- Strings inside `start_config_params`: `%s: mode %s tDstFormat %d hwFormat %d tDstRate %d hwRate %d tHalRate %d tHalFormat %d lastHalFormat %d lastRate %d`
  and `%s: mode %s resample %d d2p_enable %d dsd2pcm_rate_dst %d`.
- Runtime logs: `fiioaudio: start_config_params: mode RESAMPLE tDstFormat ...`, `fiioprocess: processAudioEvent:Insufficient audio processing efficiency ret = 0!`, `AudioStream: ... no more data to write bytes ...`.

**Find the sites.** The exported symbols are stubs (`b <real function>`); follow the branch.

In `start_config_params`, after the two log calls above, the stock code computes a
"changed" flag in a register (`w12` in 1.0.2) from several compares, then falls into a block
that zeroes eight ring-buffer indices via large-offset stores and clears a byte flag. The
flag only affects the return value; the stores run regardless:

```
cmp    w22, w27  / b.ne ... ; cmp w26, w21 / b.ne ... ; cmp w20, w19 / b.ne ...
...                          ; (sets w12 = 1 if anything changed, else 0)
mov    w8,  #0x500000  ; mov w9, #0x8 ; movk w9, #0x50, lsl #16 ; mov w10, #0x10 ; movk w10, ...
cmp    w12, #0x0                      ;  <-- SITE A (1.0.2: 0x16574)
str    xzr, [x28, x8]                 ;  ring index resets begin (0x500000, 0x500008, 0x500010, 0x500018,
str    wzr, [x28, x9]                 ;   0xa00030, 0xa00038, 0xa00040, 0xa00048 off the globals base)
...
cset   w0,  ne                        ;  <-- SITE B (1.0.2: 0x165b4)  return value = changed
...
strb   wzr, [x8, #0x74]               ;  clears a "started" byte in the state struct
ldr    x8,  [sp, #0x50]               ;  <-- EPILOGUE START (1.0.2: 0x165d0) stack-protector check
...
ret
```

Compare `reset_player_and_pcm_cache()` to be sure you have the right block: it zeroes the
same eight offsets.

In `processAudioConfigParams` (the function that calls `start_config_params`), the stock
code sets a byte flag to 1 **before** the call:

```
adrp   x8, <globals>
mov    w9, #0x1
...
strb   w9, [x8, #0x740]               ;  <-- SITE C (1.0.2: 0x1adf4)
bl     __android_log_print
bl     fiio_audio_debug_init
...
bl     start_config_params
```

That flag makes the next processing call emit one buffer of stale data instead of pulling
from the ring, adding 20 ms of permanent delay per parameter push once the reset is gone.

**Why a stub is needed.** The HAL uses `FiiOAudioConfigParams()`'s return value: nonzero
makes it put the output stream into standby. Skipping the reset must therefore also return
0, which is two instructions (`mov w0, wzr; b <epilogue>`), and there is no spare slot at
site A. The solution is an 8-byte stub in the zero padding after `.plt`, inside the
executable LOAD segment's page but just past its declared size, and extending that
segment's `p_filesz`/`p_memsz` by 8 so the bytes are formally part of the mapping.

**Patch.**

| site | 1.0.2 offset | stock bytes | patched bytes | effect |
|---|---|---|---|---|
| A | `0x16574` | `9f 01 00 71` (`cmp w12,#0`) | `6c 8e 0a 34` (`cbz w12, 0x2b740`) | unchanged → jump to stub |
| B | `0x165b4` | `e0 07 9f 1a` (`cset w0,ne`) | `20 00 80 52` (`mov w0,#1`) | changed-path return no longer relies on flags |
| C | `0x1adf4` | `09 01 1d 39` (`strb w9,[x8,#0x740]`) | `1f 20 03 d5` (`nop`) | no forced stale buffer |
| stub | `0x2b740` | `00`×8 | `e0 03 1f 2a a3 ab ff 17` (`mov w0,wzr; b 0x165d0`) | return 0 via normal epilogue |
| phdr | `0xd0`, `0xd8` | `40 97 01 00 00 00 00 00` | `48 97 01 00 00 00 00 00` | XR LOAD filesz/memsz `0x19740` → `0x19748` |

Procedure for a new build:

1. Locate sites A, B, C and the epilogue start (first instruction of the stack-protector
   check after the last ring store) in the disassembler.
2. Find the executable LOAD segment (`flags=5`, XR). Its end `va + filesz` must be followed
   by at least 8 zero bytes in the file and must not cross into the next segment's page.
   In 1.0.2 the segment ends at `0x2b740` and the next segment starts at `0x2c000`.
   The stub goes at `va + filesz`; the two 8-byte fields at `phdr + 32` and `phdr + 40`
   (`p_filesz`, `p_memsz`) each increase by 8. Their file offsets are `e_phoff + i*56 + 32`
   and `+40` for the segment's index `i` (in 1.0.2: `0xd0` and `0xd8`).
3. Encode: `cbz wN, target` = `0x34000000 | (((target - site) >> 2 & 0x7ffff) << 5) | N`;
   `b target` = `0x14000000 | ((target - site) >> 2 & 0x3ffffff)`; `mov w0, wzr` = `0x2a1f03e0`;
   `mov w0, #1` = `0x52800020`; `nop` = `0xd503201f`. Store little-endian.
4. Disassemble the patched file and confirm: site A reads `cbz wN, <stub>`, the stub reads
   `mov w0, wzr` then `b <epilogue>`, site B reads `mov w0, #1`, site C reads `nop`.
   Confirm with `readelf -l` or the Python above that the XR segment now ends 8 bytes later.

If the register holding the changed flag is not `w12`, or the compare is not immediately
followed by the stores, stop and re-derive the block from `reset_player_and_pcm_cache()`.

### 3.3 `audio.primary.bengal.so`: HAL frame size in the presentation position

**Symptom fixed.** In NOS mode the framework output thread is 16-bit while FiiO's HAL
writes 32-bit; `GetFramesWritten()` divides the 32-bit byte count by the 16-bit frame
size, so the reported position advances at 2x. Players' AudioTrack clients discard the
implausible timestamp and fall back to estimates, which hides it in most apps but leaves
AudioFlinger's latency statistics meaningless. In OS mode both sides are 32-bit and the
patch is a no-op.

**Anchors.**

- Symbol (exported): `StreamOutPrimary::GetFramesWritten(timespec*)`.
- Related: `StreamOutPrimary::GetRenderLatency(audio_output_flags_t)` (returns 29000 µs for
  deep buffer), `pal_get_timestamp` (used only by `GetFrames`, the offload path; not here).
- Runtime: `dumpsys media.audio_flinger` → the active output thread's
  `Timestamp stats: ... rate=2.0x` in NOS mode on stock.

**Find the site.** Near the top of `GetFramesWritten`, after the mutex lock and the
flags-to-latency switch, the stock code reads the channel mask and popcounts it, then
loads the **client** format and runs a switch to get bytes per sample. Both the
"written frames" division and the "kernel frames" division reuse that same loaded value:

```
ldr    w10, [x20, #0x1ec]      ; config_.channel_mask
... popcount ...
ldr    w9,  [x20, #0x1f0]      ; config_.format            <-- PATCH THIS LOAD (1.0.2: 0x53838)
...                             ; switch on w9 -> bytes/sample (1: 16-bit ... 0x1a000002: DSD)
ldr    w14, [x20, #0x2e8]      ; fragment_size_
ldr    w0,  [x20, #0x2e4]      ; fragments_
...
udiv   x8,  x13, x8            ; mBytesWritten / frame size  -> written_frames
```

The HAL's own input format lives at `+0x2d8` (and output format at `+0x2dc`) in 1.0.2; you
can confirm the offsets from `StreamOutPrimary::Open()`, which logs
`halInputFormat %d halOutputFormat %d` right after loading them, and from
`StreamOutPrimary::write()`, which compares the two before converting.

**Patch.** Change the load's immediate from the client format field to the HAL input
format field. Same register, same base.

| | 1.0.2 offset | bytes (LE) | instruction |
|---|---|---|---|
| stock | `0x53838` | `89 f2 41 b9` | `ldr w9, [x20, #0x1f0]` |
| patched | `0x53838` | `89 da 42 b9` | `ldr w9, [x20, #0x2d8]` |

`ldr wT, [xN, #imm]` (unsigned offset, 32-bit) = `0xb9400000 | ((imm >> 2) << 10) | (N << 5) | T`.

---

## 4. Adding a firmware to `customize.sh`

`module/customize.sh` has one `do_patch` call per library:

```
do_patch "<name>" <device path> "$MODPATH/<module path>" <STOCK_SHA256> <PATCHED_SHA256> "<OFF:OLD:NEW ...>"
```

Each spec is `offset:oldbytes:newbytes` in hex, bytes exactly as stored in the file
(little-endian), no `0x` on the bytes. The installer:

1. hashes the device's library and matches it against `STOCK_SHA256` (refuses otherwise,
   with a distinct message if it sees `PATCHED_SHA256`, meaning an old module is still mounted);
2. copies it into the module;
3. for each spec, reads `len(old)/2` bytes at `offset`, aborts unless they equal `old`,
   then writes `new`;
4. hashes the result and aborts unless it equals `PATCHED_SHA256`;
5. on any abort, deletes everything it staged so nothing is installed.

To add a firmware, build the patched files on the host first (sections 2 and 3), then:

```python
# generate specs from your verified stock/patched pair; never type bytes by hand
a = open('stock/libfiioaudio.so','rb').read(); b = open('patched/libfiioaudio.so','rb').read()
regions = [(0xd0,8),(0xd8,8),(SITE_A,4),(SITE_B,4),(SITE_C,4),(STUB,8)]
diff = {i for i in range(len(a)) if a[i] != b[i]}
assert diff <= {i for o,n in regions for i in range(o,o+n)}, "unexpected bytes differ"
print(' '.join(f'{o:#x}:{a[o:o+n].hex()}:{b[o:o+n].hex()}' for o,n in regions))
```

Then either add a second `case` arm keyed on the new stock hash (the current script
supports one hash per library; the straightforward extension is a `case "$sum" in` with one
arm per firmware selecting its own offset spec and patched hash) or, if the new firmware's
library is byte-identical to a supported one (same hash), nothing needs adding.

Run `sh -n module/customize.sh` for syntax, then test the whole flow on the device:
remove any installed copy of the module, reboot, confirm the stock hashes are live, install,
read the installer output, reboot, confirm the patched hashes are live.

---

## 5. Verification

Build the probe once (`tools/build_probe.sh`, needs Android SDK build-tools and a JDK) and
install it: `adb install -r probe/tsprobe.apk`. Grant nothing; it only plays a tone.

Run every row below in **both OS and NOS mode** (switch in FiiO's audio settings). Capture
`adb logcat -v threadtime` for the whole run and take `adb shell dumpsys media.audio_flinger`
once during playback.

| test | command | pass criteria |
|---|---|---|
| pause cycles, 48 kHz | `am start -n com.test.tsprobe/.MainActivity --ei rate 48000 --ei bufms 500 --ei secs 75 --ei cyclems 12000` | `queued_ms` and `head_minus_ts_ms` constant across all cycles (±5 ms) |
| pause cycles, 44.1 kHz | same with `--ei rate 44100` | same |
| new track every 6 s, 48 kHz | `--ei rate 48000 --ei bufms 500 --ei secs 60 --ei newtrackms 6000` | `head_minus_ts_ms` identical on every `TRACK n` |
| new track every 6 s, 44.1 kHz | same with `--ei rate 44100` | same |

In the logcat for each run:

- `grep -c 'goto create retrack'` must be **0** (patch 1).
- `grep -c 'no more data to write'` must be **0**, and `Insufficient audio processing
  efficiency` must not appear after the first track (patch 2).
- No `F DEBUG` / crash entries for `audioserver` or `android.hardware.audio.service`.

In the `dumpsys media.audio_flinger` excerpt for the active output thread (the one with
`Standby: no`):

- `Timestamp stats: ... rate=` between **0.99 and 1.03** in both modes (patch 3; stock NOS shows ~2.0).
- `Threadloop write latency stats: ave=` a plausible positive number (roughly 80 to 200 ms
  on this device), not negative or in the millions.

Reference values from 1.0.2 after the fix: OS 384 kHz thread `head_minus_ts_ms=87`,
thread latency 87.6 ms; NOS 44.1 kHz `159`, 159 ms; NOS 48 kHz `148`, 148 ms.

Then test by eye, in both modes:

1. Play a YouTube video with visible lip sync. Pause and resume ten times, a few seconds
   apart. Sync must not drift.
2. Swipe through fifteen YouTube Shorts. Sync on the last one must match the first.
3. Play 96 or 192 kHz content, then 44.1 kHz, then pause/resume. This exercises the
   "parameters actually changed" path, which still performs the full reset, so it must
   behave like stock (a brief mute at the change is normal).

Finally confirm the fix is reversible: disable the module in Magisk, reboot, and check the
three live hashes are back to stock.

---

## 6. Pull request checklist

Before opening a PR that adds a firmware or device, include in the description:

- [ ] Device model, firmware version, `ro.build.fingerprint`.
- [ ] Stock and patched SHA-256 for all three libraries, matching the `customize.sh` entry.
- [ ] For each patch site: the function name, the offset, the stock and patched
      disassembly lines (copy from `objdump` output on your files).
- [ ] Probe logs for all four probe rows in **both** OS and NOS (`adb logcat -s TSPROBE`
      output only; it contains no identifiers), named like the files in `logs/`.
- [ ] The `dumpsys media.audio_flinger` excerpt for the active thread (sample rate, HAL
      format, `Timestamp stats`, `Threadloop write latency` lines only). Do **not** attach a
      full `dumpsys` or full `logcat`: they contain the device serial, account names, and
      package lists. If you must quote more, scrub serial numbers, IMEI/board numbers,
      Wi-Fi SSIDs, and account e-mail addresses first.
- [ ] Which modes and tests you ran by eye (section 5), and the result of the rollback check.
- [ ] Confirmation that the PR contains no `.img`, `.so`, or other firmware-derived binaries
      (the `.gitignore` blocks the common cases; check `git status` anyway).

If any probe row fails, do not open the PR with the module change; open an issue with the
logs instead so the failing site can be re-derived.
