# FiiO M33 R2R A/V sync fix

A Magisk module that fixes audio running ahead of video and lyrics on the FiiO M33 R2R.
On stock firmware the gap grows every time you pause and resume, and again with every new
clip in apps that create a fresh player per item (YouTube Shorts, playlists). Only a reboot
clears it.

The module ships **no FiiO binaries**. At install time it copies the device's own audio
libraries, verifies each is a known stock build by SHA-256, changes a handful of
instructions, verifies the results, and mounts the patched copies systemlessly. If any
check fails it installs nothing. Disabling the module restores stock behaviour.

> **No warranty.** This modifies system and vendor libraries on a rooted device. It has
> been tested on one M33 R2R running firmware 1.0.2. Rooting and flashing can brick a
> device and will affect any warranty or return. You do this at your own risk.

## Is this for you?

- **Device:** FiiO M33 R2R. Other FiiO Android DAPs share the same framework patches but
  are untested; see [PORTING.md](PORTING.md).
- **Firmware:** 1.0.2 (build `FiiO04281702`). The installer refuses any other build.
  1.0.3 has the same symptoms but its libraries have not been verified yet; if you are on
  1.0.3, see [Supported firmware](#supported-firmware) for how to help.
- **Symptom:** on the wired headphone output, audio leads video in YouTube and other
  players, worse after each pause/resume, worse with every Short. Happens in both OS and
  NOS modes with no EQ or effects.
- **Requirements:** unlocked bootloader (the M33 R2R ships unlocked), `adb` and `fastboot`,
  willingness to root with Magisk.

## Install

1. **Get your stock `init_boot`.** Extract `init_boot.img` from the FiiO OTA zip for the
   exact firmware you are running (it is inside `payload.bin`; use a payload dumper such
   as `payload-dumper-go`). This device has an `init_boot` partition, so Magisk patches
   `init_boot`, **not** `boot`. Keep an unmodified copy and its SHA-256; it is your rollback.
2. **Patch it with Magisk.** Install the [Magisk app](https://github.com/topjohnwu/Magisk/releases),
   choose Install, "Select and Patch a File", pick `init_boot.img`, and copy the patched
   image back to your computer.
3. **Flash only `init_boot` on the active slot.**
   ```
   adb reboot bootloader
   fastboot getvar current-slot          # prints a or b
   fastboot flash init_boot_b magisk_patched.img   # use init_boot_a if the slot is a
   fastboot reboot
   ```
   Do not flash `vbmeta` or anything else.
4. **Finish Magisk setup.** Open the Magisk app, accept its one-time "additional setup"
   reboot, and confirm the Home tab shows Installed. Magisk 31 and later have no root
   prompt: root is granted per app in the Superuser tab (grant "Shell" if you want
   `adb shell su`).
5. **Install the module.** Download the zip from the
   [Releases page](https://github.com/ryanmagoon/fiio-m33-r2r-avsync-fix/releases), then in
   Magisk open Modules, "Install from storage", pick the zip, read the installer output
   (it prints each library's hash and "patched OK"), and reboot.

Verify (expect the three "after patch" hashes from the table below):

    adb shell sha256sum /system/lib64/libaudioclient.so /vendor/lib64/libfiioaudio.so /vendor/lib64/hw/audio.primary.bengal.so

## Rollback

- **Undo the fix only:** disable or remove the module in the Magisk app and reboot. The
  stock libraries on disk are never modified. Details in [`module/uninstall.md`](module/uninstall.md).
- **Full unroot:** flash your saved stock `init_boot.img` back to the same slot with
  `fastboot flash init_boot_<slot>`.

## Before you update firmware

A firmware update replaces `init_boot` (removing Magisk) and very likely replaces the
patched libraries. The installer refuses unknown libraries, so re-enabling the module after
an update will simply fail until the new build is listed as supported. Disable the module
before updating to be safe.

## Supported firmware

| library | firmware 1.0.2 stock SHA-256 | after patch |
|---|---|---|
| `/system/lib64/libaudioclient.so` | `221084582f2ed50fca14a04918e301e530b63e0343b94028a7c5cc48623532d7` | `fce12ea84fce63aa12f6b593d6a87dcdc2797fe5e0e5520861c87247f1199173` |
| `/vendor/lib64/libfiioaudio.so` | `2fbb367bfcff06e0fd1b2d94ad994edacee27280792d5b74d202d8a50d59d563` | `a0203d703185ea30bf048887fc22b3037acf148d13f23f7038f8152a77ddd191` |
| `/vendor/lib64/hw/audio.primary.bengal.so` | `855df110b8d7d2b5b0d01354d78bec6a0b9cc9933d1a7661c17ae49587bbe6d2` | `d16c987bceea3d184cb19c0f9e25de5c89dcc50c10c73817dc56d1615997b3ac` |

**On 1.0.3 or another build?** Two ways to help:

- Open an issue titled with your firmware version and paste the output of the `sha256sum`
  command above plus `adb shell getprop ro.build.fingerprint`.
- Or port the patches yourself with [PORTING.md](PORTING.md), which walks through locating
  each site, verifying the bytes, and adding the hashes to the installer.

The 32-bit `/system/lib/libaudioclient.so` is not patched; the audio framework and every
relevant app on this device are 64-bit.

## How it works

Three separate defects in FiiO's modifications to Android's audio stack, all between an
app's `AudioTrack` and the DAC. None is in the DAC or the FPGA.

**1. Forced AudioTrack recreation on every start** (`libaudioclient.so`). FiiO's
`AudioTrack::config_audio_params()` runs on every `start()`. When the track's sample rate or
format differs from the output thread's (384 kHz, 32-bit in OS mode), which is true for
nearly every app, it logs `goto create retrack for sample rate or format not match` and
recreates the server-side track. Audio already queued in the app's buffer moves to the new
track, but the position bookkeeping players use for A/V sync does not account for it, so
each pause/resume pushes the reported position behind the audio by about the queued amount.

**2. Processing ring buffers reset on every parameter push** (`libfiioaudio.so`). On every
`createTrack`, FiiO's AudioFlinger pushes `sampling_rate` and `format` to the HAL, even when
unchanged. FiiO's processing library then zeroes its input and output ring buffers
unconditionally, discarding queued audio, and re-primes with two 20 ms buffers the
framework counts but the HAL never writes. Each new track puts the real audio about 40 ms
further ahead of the counted position, permanently.

**3. Presentation position at 2x in NOS mode** (`audio.primary.bengal.so`). The HAL's
`GetFramesWritten()` divides its byte count by the *client's* frame size. The HAL writes
32-bit, and in NOS mode the framework thread is 16-bit, so the position advances at twice
real time. Android's `AudioTrack` client discards the implausible timestamp and falls back
to an estimate, which hides it in most players but leaves AudioFlinger's latency figures
meaningless.

### Measurements

Probe app in [`probe/`](probe/), one `AudioTrack` at 48 kHz 16-bit with a 500 ms buffer,
stock firmware vs. this module. "Queued" is audio the app has written that the playback
head has not passed; it cannot legitimately exceed the buffer size.

| scenario | stock | fixed |
|---|---|---|
| pause 4 s every 12 s, queued after 0/1/2/3/4 cycles | 250 / 480 / 710 / 940 / 1170 ms | 250 ms throughout |
| new track every 6 s, head minus timestamp, tracks 1 to 10 | 486 ms rising 40 ms per track to 866 ms | 87 ms on every track |
| 10 YouTube Shorts, AudioFlinger thread write latency | 88 ms rising to 521 ms | 87.6 ms flat |
| NOS mode, 44.1 kHz, AudioFlinger timestamp rate | 2.04x | 1.01x |

Raw logs are in [`logs/`](logs/).

### What the patches change

File offsets in the firmware 1.0.2 libraries. Nothing else on the device is touched.

`libaudioclient.so`, `AudioTrack::config_audio_params`, one instruction:

| offset | stock | patched |
|---|---|---|
| `0xa0ed8` | `b.ne 0xa0ee8` (go recreate the track) | `b 0xa0f24` (skip recreation) |

`libfiioaudio.so`, `start_config_params` and `processAudioConfigParams`:

| offset | stock | patched |
|---|---|---|
| `0x16574` | `cmp w12, #0` | `cbz w12, 0x2b740` (parameters unchanged: skip the ring reset) |
| `0x165b4` | `cset w0, ne` | `mov w0, #1` (changed-path return value no longer depends on flags) |
| `0x1adf4` | `strb w9, [x8, #0x740]` | `nop` (no forced stale buffer on every parameter push) |
| `0x2b740` | zero padding | `mov w0, wzr; b 0x165d0` (return "unchanged" to the HAL) |
| `0xd0`, `0xd8` | executable segment size `0x19740` | `0x19748` (covers the 8-byte stub) |

`audio.primary.bengal.so`, `StreamOutPrimary::GetFramesWritten`, one instruction:

| offset | stock | patched |
|---|---|---|
| `0x53838` | `ldr w9, [x20, #0x1f0]` (client format) | `ldr w9, [x20, #0x2d8]` (HAL input format) |

## Known issues not addressed here

- **Audible read-along offset.** Audible's text highlighting runs out of step with the
  narration on this device as well. That is a separate app-side synchronisation and is not
  changed by this module.
- **32-bit apps** still get the stock `libaudioclient.so` behaviour (see above).

## Repository layout

| path | contents |
|---|---|
| [`module/`](module/) | Magisk module source: `module.prop`, `customize.sh` (install-time patcher), `uninstall.md` |
| [`probe/`](probe/) | Source and APK of the AudioTrack probe app used to measure the bug (`com.test.tsprobe`) |
| [`logs/`](logs/) | Probe output and AudioFlinger excerpts before and after each fix |
| [`tools/`](tools/) | `build_probe.sh`: builds the probe APK with the Android SDK build-tools |
| [`PORTING.md`](PORTING.md) | Step-by-step guide for porting the patches to another firmware or device |

## Probe app

`tsprobe` plays a tone through an `AudioTrack` and logs, once per second, frames written,
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
