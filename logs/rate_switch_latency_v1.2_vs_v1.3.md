# Hardware sample-rate switches: AudioFlinger write latency, v1.2 vs v1.3

Firmware 1.0.2, OS mode, wired output. Probe app (`probe/`) started repeatedly with
`--ei rate 48000` and `--ei rate 44100` (10 s each, 13 s apart). Each change between a 48 kHz
and a 44.1 kHz track makes FiiO's HAL switch the hardware between 384 kHz and 352.8 kHz,
which restarts the processing thread. Values are `Threadloop write latency stats: ave` for
`AudioOut_1D` from `dumpsys media.audio_flinger`, read about 9 s into each run.
`disc` is the thread's timestamp discontinuity count, which increments once per switch.

## v1.2 (patch 4 absent)

Fresh boot, then eight runs:

| run | thread rate after | latency ave (ms) | starvation log |
|---|---|---|---|
| boot | 352800 | 107.9 | |
| 48000 | 384000 | 104.9 | |
| 44100 (float) | 384000 | 121.0 | |
| 88200 (float) | 352800 | 145.7 | `no more data to write bytes 56448` |
| 48000 | 352800 | 146.5 | |
| 44100 | 352800 | 147.4 | |
| 96000 (32-bit) | 384000 | 141.9 | |
| 48000 | 384000 | 141.0 | |
| 88200 (float) | 352800 | 165.6 | `no more data to write bytes 56448` |

Second series, three full round trips (only runs 1, 4 and 7 actually switched the rate):

| run | thread rate after | disc | latency ave (ms) |
|---|---|---|---|
| start | 352800 | | 160.6 |
| 48000 | 384000 | 34 | 161.2 |
| 44100 | 384000 | 34 | 161.2 |
| 48000 | 384000 | 34 | 154.7 |
| 44100 | 352800 | 35 | 187.6 |
| 48000 | 352800 | 35 | 187.8 |
| 44100 | 352800 | 35 | 181.2 |
| 48000 | 384000 | 36 | 179.5 |

The probe's own `head_minus_ts_ms` moved with it: 142 → 167 → 161 → 188 → 179.

The user's device after 23 h of Apple Music: `ave=687.8 std=3.75 min=676.8 max=728.0`.

Every switch to 352.8 kHz was accompanied by
`W/fiioprocess: processAudioEvent:Insufficient audio processing efficiency ret = 0!` followed by
`W/AudioStream: out_write: 1321: no more data to write bytes 56448`.

## v1.3 (patch 4 present)

Fresh boot, then ten runs, every one of which switched the hardware rate (`disc` 1 → 10):

| run | thread rate after | disc | latency ave (ms) | probe head_minus_ts_ms |
|---|---|---|---|---|
| 48000 | 384000 | 1 | 80.7 | 85 |
| 44100 | 352800 | 2 | 80.6 | 85 |
| 48000 | 384000 | 3 | 80.5 | 84 |
| 44100 | 352800 | 4 | 80.4 | 85 |
| 48000 | 384000 | 5 | 80.4 | 84 |
| 44100 | 352800 | 6 | 80.7 | 85 |
| 48000 | 384000 | 7 | 80.4 | 84 |
| 44100 | 352800 | 8 | 80.5 | 85 |
| 48000 | 384000 | 9 | 80.6 | 84 |
| 44100 | 352800 | 10 | 80.7 | 84 |

No `Insufficient audio processing efficiency`, `no more data` or `fill zero data` lines in the
whole series. Regression probes afterwards: pause/resume cycles `queued_ms=250`,
`head_minus_ts_ms` 84 to 85 on every cycle; new track every 6 s, 84 to 85 ms on every track;
AudioFlinger latency 79 ms after both.
