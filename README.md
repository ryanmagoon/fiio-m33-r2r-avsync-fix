# FiiO M33 R2R audio lag fixes

Magisk module for the FiiO M33 R2R. On stock firmware audio drifts ahead of video and
lyrics with every pause/resume and every new clip (YouTube Shorts, playlists), and output
delay builds up over hours of playback that mixes 44.1 and 48 kHz material. Only a reboot
clears it. This module fixes four defects in FiiO's audio stack that cause it.

It ships **no FiiO binaries**. At install time it verifies the device's own audio libraries
by SHA-256, patches a few instructions in copies of them, and mounts the copies
systemlessly. If any check fails it installs nothing.

> **No warranty.** This modifies system and vendor libraries on a rooted device. It has
> been tested on one M33 R2R running firmware 1.0.2. Rooting and flashing can brick a
> device and will affect any warranty or return. You do this at your own risk.

## Is this for you?

- **Device:** FiiO M33 R2R. Other FiiO Android DAPs are untested; see [PORTING.md](PORTING.md).
- **Firmware:** 1.0.2 (build `FiiO04281702`). The installer refuses any other build.
- **Symptom:** on the wired headphone output, audio leads video in YouTube and other
  players, worse after each pause/resume and with every Short; or audio falls behind
  lyrics after hours of use (Apple Music). Both OS and NOS modes.
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
   (it prints each library's hash and "patched OK"), and reboot. Upgrading from an earlier
   version works the same way: install the new zip over it and reboot.

Verify (expect the three "after patch" hashes from the table below):

    adb shell sha256sum /system/lib64/libaudioclient.so /vendor/lib64/libfiioaudio.so /vendor/lib64/hw/audio.primary.bengal.so

## Rollback

- **Undo the fix only:** disable or remove the module in the Magisk app and reboot. The
  stock libraries on disk are never modified. Details in [`module/uninstall.md`](module/uninstall.md).
- **Full unroot:** flash your saved stock `init_boot.img` back to the same slot with
  `fastboot flash init_boot_<slot>`.

## Firmware

| library | firmware 1.0.2 stock SHA-256 | after patch |
|---|---|---|
| `/system/lib64/libaudioclient.so` | `221084582f2ed50fca14a04918e301e530b63e0343b94028a7c5cc48623532d7` | `fce12ea84fce63aa12f6b593d6a87dcdc2797fe5e0e5520861c87247f1199173` |
| `/vendor/lib64/libfiioaudio.so` | `2fbb367bfcff06e0fd1b2d94ad994edacee27280792d5b74d202d8a50d59d563` | `286523a244093ee48b3e3ad80904488cc1943e189e3bf6d8eb4be3d18d1c1cac` |
| `/vendor/lib64/hw/audio.primary.bengal.so` | `855df110b8d7d2b5b0d01354d78bec6a0b9cc9933d1a7661c17ae49587bbe6d2` | `d16c987bceea3d184cb19c0f9e25de5c89dcc50c10c73817dc56d1615997b3ac` |

**Disable the module before a firmware update.** An update replaces `init_boot` (removing
Magisk) and very likely the patched libraries; the installer will refuse the new build until
it is listed here.

**On 1.0.3 or another build?** Open an issue titled with your firmware version and paste
the output of the `sha256sum` command above plus `adb shell getprop ro.build.fingerprint`,
or port the patches yourself with [PORTING.md](PORTING.md). `tools/regression.sh` runs the
automated checks for all four fixes over adb in about seven minutes per output mode, and
`bun test` replays them against the committed v1.2 (failing) and v1.3 (passing) captures.

## How it works

Four defects in FiiO's modifications to Android's audio stack, all between an app's
`AudioTrack` and the DAC. None is in the DAC or the FPGA.

- **`libaudioclient.so`** recreates the server-side track on every `start()` when the app's
  rate or format differs from the output's (nearly always). Queued audio moves to the new
  track but the position players use for A/V sync does not, so each pause/resume pushes
  audio further ahead. Patch: one branch, skip the recreation.
- **`libfiioaudio.so`** zeroes its processing ring buffers on every parameter push, which
  FiiO's AudioFlinger issues on every new track even when nothing changed. About 40 ms of
  audio is lost from the count per track, permanently. Patch: reset only when parameters
  actually change.
- **`libfiioaudio.so`**, second defect: after a real hardware rate change (384 kHz for 48 kHz
  material, 352.8 kHz for 44.1 kHz) its processing thread restarts and is late with its
  first output. The library then returns zero bytes, and the HAL tells AudioFlinger the
  buffer was written anyway. The unwritten 20 ms stays queued forever, so the real delay
  ratchets up on every switch (688 ms after a day of Apple Music). Patch: wait up to 20 ms
  for the thread instead of returning zero.
- **`audio.primary.bengal.so`** computes the presentation position with the client's frame
  size while writing 32-bit, so in NOS mode (16-bit thread) the position runs at 2x. Patch:
  use the HAL's own format.

Exact offsets, stock and patched bytes, and how to find the sites on another build are in
[PORTING.md](PORTING.md). Before/after measurements and raw probe logs are in
[`logs/`](logs/); the probe app is in [`probe/`](probe/).

## Known issues not addressed here

- **32-bit apps** still get the stock `libaudioclient.so` behaviour; the 32-bit library is
  not patched. The audio framework and every relevant app on this device are 64-bit.

## License

MIT. See [`LICENSE`](LICENSE).
