# FiiO M33 R2R A/V sync fix

A Magisk module that fixes audio running ahead of video (and lyrics) on the FiiO M33 R2R,
where the gap grows every time playback is paused and resumed, and grows again with every
new clip in apps that create a fresh player per item (YouTube Shorts, playlists).

The module ships **no FiiO binaries**. At install time it copies the device's own audio
libraries, verifies each one is a known stock build by SHA-256, changes a handful of
instructions, verifies the results, and mounts the patched copies systemlessly. If
anything does not match, it installs nothing.

> **No warranty.** This modifies system and vendor libraries on a rooted device. It worked
> on one M33 R2R on firmware 1.0.2. Rooting and flashing can brick a device and will affect
> any warranty or return. You do this at your own risk.

## Symptom

On the wired internal DAC, audio leads the video in YouTube and other players. The lead
gets larger after each pause/resume, and in YouTube Shorts it gets larger with every swipe.
A few pauses or Shorts in, the offset is well over half a second. It happens in both OS
and NOS modes, with no EQ or effects, and only an audioserver restart (reboot) clears it.

## Root causes

Three separate defects in FiiO's modifications to Android's audio stack, all on the path
from an app's `AudioTrack` to the DAC. None of them is in the DAC or the FPGA.

### 1. Forced AudioTrack recreation on every start (framework, `libaudioclient.so`)

FiiO added `AudioTrack::config_audio_params()`, called on every `start()`. It compares the
track's sample rate and format with the output thread's (384 kHz, 32-bit in OS mode). When
they differ, which is the case for essentially every app, it logs

    goto create retrack for sample rate or format not match

and recreates the server-side track. The audio already queued in the app's buffer is moved
to the new track, but the playback-head and timestamp bookkeeping that players use for
A/V sync does not account for it. Each pause/resume therefore makes the reported position
fall behind the audio actually heard by roughly the amount queued at that moment.

### 2. Processing ring buffers reset on every parameter push (vendor, `libfiioaudio.so`)

FiiO's AudioFlinger pushes `sampling_rate` and `format` to the audio HAL on every
`createTrack`, even when identical to the previous track. The HAL hands them to FiiO's
processing library, whose `start_config_params()` **unconditionally zeroes its input and
output ring buffers**, discarding whatever audio was queued, then re-primes with two 20 ms
buffers that the framework counts as written but the HAL never passes on. Net effect per new
track: the real audio jumps about 40 ms ahead of the counted position, permanently.

### 3. Presentation position at 2x in NOS mode (vendor HAL, `audio.primary.bengal.so`)

`StreamOutPrimary::GetFramesWritten()` divides the HAL's byte count by the *client's* frame
size. FiiO's HAL converts everything to 32-bit before writing, and in NOS mode the framework
thread is 16-bit, so the reported position advances at twice real time. Android's
`AudioTrack` client discards the implausible timestamp and falls back to an estimate, which
masks the error for most players but leaves AudioFlinger's latency statistics meaningless.

### Measurements

Probe app (`probe/`), one `AudioTrack` at 48 kHz 16-bit with a 500 ms buffer, stock firmware
vs. this module. "Queued" is audio written by the app that the playback head has not yet
passed; it cannot legitimately exceed the buffer size.

| scenario | stock | fixed |
|---|---|---|
| pause 4 s every 12 s, queued after 0/1/2/3/4 cycles | 250 / 480 / 710 / 940 / 1170 ms | 250 ms throughout |
| new track every 6 s, head minus timestamp, tracks 1 to 10 | 486 ms rising by 40 ms per track to 866 ms | 87 ms on every track |
| 10 YouTube Shorts, AudioFlinger thread write latency | 88 ms rising to 521 ms | 87.6 ms flat |
| NOS mode, 44.1 kHz, AudioFlinger timestamp rate | 2.04x | 1.01x |

Raw logs are in [`logs/`](logs/).

## What the patches change

All offsets are file offsets in the firmware 1.0.2 libraries. Everything else on the device
is untouched.

**`/system/lib64/libaudioclient.so`** (`AudioTrack::config_audio_params`, 1 instruction)

| offset | stock | patched |
|---|---|---|
| `0xa0ed8` | `b.ne 0xa0ee8` (go recreate the track) | `b 0xa0f24` (skip recreation) |

**`/vendor/lib64/libfiioaudio.so`** (`start_config_params`, `processAudioConfigParams`)

| offset | stock | patched |
|---|---|---|
| `0x16574` | `cmp w12, #0` | `cbz w12, 0x2b740` (if parameters unchanged, skip the ring reset) |
| `0x165b4` | `cset w0, ne` | `mov w0, #1` (changed-path return value no longer depends on flags) |
| `0x1adf4` | `strb w9, [x8, #0x740]` | `nop` (do not force one stale buffer on every parameter push) |
| `0x2b740` | zero padding | `mov w0, wzr; b 0x165d0` (return "unchanged" to the HAL) |
| `0xd0`, `0xd8` | executable segment size `0x19740` | `0x19748` (covers the 8-byte stub) |

**`/vendor/lib64/hw/audio.primary.bengal.so`** (`StreamOutPrimary::GetFramesWritten`, 1 instruction)

| offset | stock | patched |
|---|---|---|
| `0x53838` | `ldr w9, [x20, #0x1f0]` (client format) | `ldr w9, [x20, #0x2d8]` (HAL input format) |

### Supported firmware

The installer accepts only these stock hashes and verifies the result against the patched
hashes. Unknown builds are refused and nothing is installed.

| library | firmware 1.0.2 stock SHA-256 | after patch |
|---|---|---|
| `libaudioclient.so` | `221084582f2ed50fca14a04918e301e530b63e0343b94028a7c5cc48623532d7` | `fce12ea84fce63aa12f6b593d6a87dcdc2797fe5e0e5520861c87247f1199173` |
| `libfiioaudio.so` | `2fbb367bfcff06e0fd1b2d94ad994edacee27280792d5b74d202d8a50d59d563` | `a0203d703185ea30bf048887fc22b3037acf148d13f23f7038f8152a77ddd191` |
| `audio.primary.bengal.so` | `855df110b8d7d2b5b0d01354d78bec6a0b9cc9933d1a7661c17ae49587bbe6d2` | `d16c987bceea3d184cb19c0f9e25de5c89dcc50c10c73817dc56d1615997b3ac` |

Firmware 1.0.3 shows the same symptoms but its libraries have not been hashed or verified.
If you are on 1.0.3, please open an issue with the output of:

    adb shell sha256sum /system/lib64/libaudioclient.so /vendor/lib64/libfiioaudio.so /vendor/lib64/hw/audio.primary.bengal.so

The 32-bit `/system/lib/libaudioclient.so` is not patched; all relevant apps and the audio
framework on this device are 64-bit.

## Install

You need an unlocked bootloader (the M33 R2R ships with `flash.locked=0`), `adb` and
`fastboot`, and the Magisk app.

1. **Get your stock `init_boot`.** Extract `init_boot.img` from the FiiO OTA zip for the
   exact firmware version you are running (`payload.bin` inside the zip; use a payload
   dumper). This device has an `init_boot` partition, so Magisk patches `init_boot`, not
   `boot`. Keep an unmodified copy; it is your rollback.
2. **Patch it with Magisk.** Install the Magisk app, use "Install > Select and Patch a
   File" on `init_boot.img`, and copy the patched image back to your computer.
3. **Flash only `init_boot` to the active slot.** Check the slot first:
   ```
   adb reboot bootloader
   fastboot getvar current-slot
   fastboot flash init_boot_b magisk_patched.img   # use init_boot_a if current-slot is a
   fastboot reboot
   ```
   Do not flash `vbmeta` or anything else.
4. Open the Magisk app, accept its one-time "additional setup" reboot, and confirm it
   shows Installed. Magisk 31 and later have no root prompt: grant root per app in the
   Superuser tab (including "Shell" if you want `adb shell su`).
5. **Install this module.** Download the zip from the Releases page, then in Magisk go to
   Modules > Install from storage, pick the zip, and reboot. The installer prints each
   library's hash and whether it patched it.

To verify afterwards (expect the three "after patch" hashes above):

    adb shell sha256sum /system/lib64/libaudioclient.so /vendor/lib64/libfiioaudio.so /vendor/lib64/hw/audio.primary.bengal.so

## Rollback

- **Undo the fix only:** disable or remove the module in the Magisk app and reboot. The
  stock libraries on disk are never modified. See [`module/uninstall.md`](module/uninstall.md).
- **Full unroot:** flash your saved stock `init_boot.img` back to the same slot with
  `fastboot flash init_boot_<slot>`.

## OTA warning

A firmware update replaces `init_boot` (removing Magisk) and very likely replaces these
libraries. After updating, do not re-enable this module until the new hashes are listed
above as supported. The installer refuses unknown libraries, but check anyway.

## Known issues not addressed here

- **Audible read-along offset.** Audible's text highlighting runs out of step with the
  narration on this device as well. That is a separate app-side synchronisation and is
  not changed by this module.
- **32-bit apps** still get the stock `libaudioclient.so` behaviour (see above).

## Repository layout

| path | contents |
|---|---|
| `module/` | Magisk module source: `module.prop`, `customize.sh` (install-time patcher), `uninstall.md` |
| `probe/` | Source and APK of the AudioTrack probe app used to measure the bug (`com.test.tsprobe`) |
| `logs/` | Probe output and AudioFlinger excerpts before and after each fix |
| `tools/` | Script to build the probe APK with the Android SDK build-tools |

## Probe app

`tsprobe` plays a tone through an `AudioTrack` and logs frames written,
`getPlaybackHeadPosition()`, and `getTimestamp()`. Intent extras: `rate`, `enc` (2 = 16-bit,
22 = 32-bit, 4 = float), `bufms`, `secs`, `cyclems` (pause 4 s every N ms), `newtrackms`
(destroy and recreate the track every N ms, like Shorts), `click` (click train with a screen
flash at the timestamp-predicted instant).

    adb install -r probe/tsprobe.apk
    adb shell am start -n com.test.tsprobe/.MainActivity --ei bufms 500 --ei secs 75 --ei cyclems 12000
    adb shell am start -n com.test.tsprobe/.MainActivity --ei bufms 500 --ei secs 60 --ei newtrackms 6000
    adb logcat -s TSPROBE

`queued_ms` and `head_minus_ts_ms` should stay roughly constant across cycles and tracks.
On stock firmware they grow by about one buffer-fill per pause and 40 ms per new track.

## License

MIT. See [`LICENSE`](LICENSE).
