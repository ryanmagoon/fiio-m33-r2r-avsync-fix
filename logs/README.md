# Measurements

Probe app in [`../probe/`](../probe/), one `AudioTrack` at 48 kHz 16-bit with a 500 ms
buffer unless noted, stock firmware vs. the module. "Queued" is audio the app has written
that the playback head has not passed; it cannot legitimately exceed the buffer size.

| scenario | stock | fixed | logs |
|---|---|---|---|
| pause 4 s every 12 s, queued after 0/1/2/3/4 cycles | 250 / 480 / 710 / 940 / 1170 ms | 250 ms throughout | `before_patch_probe_cycles.log`, `after_patch_probe_cycles.log` |
| new track every 6 s, head minus timestamp, tracks 1 to 10 | 486 ms rising 40 ms per track to 866 ms | 87 ms on every track | `before_patch_new_track_every_6s.log`, `after_patch_new_track_every_6s.log` |
| 10 YouTube Shorts, AudioFlinger thread write latency | 88 ms rising to 521 ms | 87.6 ms flat | `audioflinger_thread_stats.md` |
| NOS mode, 44.1 kHz, AudioFlinger timestamp rate | 2.04x | 1.01x | `nos_44k1_before_hal_patch_probe_cycles.log`, `nos_44k1_after_patch_probe_cycles.log` |
| OS mode, 48 kHz, module v1.2 | | 1.01x, 87.6 ms | `os_48k_v1.2_probe_cycles.log` |

Logs are `TSPROBE` logcat lines only, with pids and device identifiers removed.
