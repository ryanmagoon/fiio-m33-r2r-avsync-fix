# tsprobe

A minimal `AudioTrack` probe used to measure the A/V sync bug. It plays a tone and logs,
once per second, frames written, `getPlaybackHeadPosition()`, and `getTimestamp()`.

Intent extras:

| extra | meaning |
|---|---|
| `rate` | sample rate (default 48000) |
| `enc` | 2 = 16-bit, 22 = 32-bit, 4 = float |
| `bufms` | AudioTrack buffer size in ms |
| `secs` | run length |
| `cyclems` | pause 4 s every N ms |
| `newtrackms` | destroy and recreate the track every N ms (like YouTube Shorts) |
| `click` | click train with a screen flash at the timestamp-predicted instant |

    adb install -r probe/tsprobe.apk
    adb shell am start -n com.test.tsprobe/.MainActivity --ei bufms 500 --ei secs 75 --ei cyclems 12000
    adb shell am start -n com.test.tsprobe/.MainActivity --ei bufms 500 --ei secs 60 --ei newtrackms 6000
    adb logcat -s TSPROBE

`queued_ms` and `head_minus_ts_ms` should stay roughly constant across cycles and tracks.
On stock firmware they grow by about one buffer-fill per pause and 40 ms per new track.

Rebuild from source with `tools/build_probe.sh` (Android SDK build-tools and a JDK; no Gradle).
