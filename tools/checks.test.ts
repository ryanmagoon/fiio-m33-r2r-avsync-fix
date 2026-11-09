// Offline red/green test of the regression checks against committed device captures.
// Red fixtures were captured on module v1.2 (bug present), green ones on v1.3, same device,
// same day. A check is only trusted if it fails on red and passes on green.
import { describe, expect, test } from "bun:test";
import { logScan, newTrack, pauseCycles, rateSwitches, threadDump, timestampRate } from "./checks";

const RED = "logs/regression-v1.3-red";
const GREEN_OS = "logs/regression-v1.3-os";
const GREEN_NOS = "logs/regression-v1.3-nos";

describe("rate switches (patch 4)", () => {
  test("red: latency ratchets ~20 ms per switch on v1.2", () => {
    const r = rateSwitches(`${RED}/rate_switches.txt`);
    expect(r.ok).toBe(false);
    expect(r.detail).toContain("max_spread_at_same_rate=80");
  });
  test("green: flat within 5 ms in OS and NOS", () => {
    expect(rateSwitches(`${GREEN_OS}/rate_switches.txt`).ok).toBe(true);
    expect(rateSwitches(`${GREEN_NOS}/rate_switches.txt`).ok).toBe(true);
  });
  test("NOS compares same-rate runs only (44.1k buffers are 8.8% longer in ms)", () => {
    // the whole-series spread in NOS is ~14 ms; grouping by rate brings it under tolerance
    const r = rateSwitches(`${GREEN_NOS}/rate_switches.txt`);
    expect(r.detail).toMatch(/44100:\[15\d/);
    expect(r.detail).toMatch(/48000:\[14\d/);
    expect(r.ok).toBe(true);
  });
});

describe("pause/resume cycles (patches 1 and 4)", () => {
  test("red: 44.1 kHz cycles grow 20 ms each on v1.2", () => {
    const r = pauseCycles(`${RED}/pause_cycles_44100.log`);
    expect(r.ok).toBe(false);
    expect(r.detail).toContain("head_minus_ts_ms=[105,125,145,165,185]");
  });
  test("red: 48 kHz cycles were already fixed by patch 1", () => {
    expect(pauseCycles(`${RED}/pause_cycles_48000.log`).ok).toBe(true);
  });
  test("queued_ms jitter of a few ms at 44.1 kHz in NOS is not drift", () => {
    const r = pauseCycles("logs/regression-v1.3-nos-jitter/pause_cycles_44100.log");
    expect(r.detail).toContain("queued_ms=[244,241,242,239,245]");
    expect(r.detail).toContain("head_minus_ts_ms=[159,159,159,159,159]");
    expect(r.ok).toBe(true);
  });
  test("green: both rates flat in both modes", () => {
    for (const dir of [GREEN_OS, GREEN_NOS]) {
      expect(pauseCycles(`${dir}/pause_cycles_48000.log`).ok).toBe(true);
      expect(pauseCycles(`${dir}/pause_cycles_44100.log`).ok).toBe(true);
    }
  });
});

describe("new track every 6 s (patch 2)", () => {
  test("green: identical on every track", () => {
    expect(newTrack(`${GREEN_OS}/new_track_48000.log`).ok).toBe(true);
    expect(newTrack(`${GREEN_NOS}/new_track_48000.log`).ok).toBe(true);
  });
  test("refuses to pass with too few tracks", () => {
    expect(newTrack(`${RED}/pause_cycles_48000.log`).ok).toBe(false);
  });
});

describe("timestamp rate (patch 3)", () => {
  test("green: within 0.99..1.03 in both modes", () => {
    expect(timestampRate(`${GREEN_OS}/rate_switches.txt`).ok).toBe(true);
    expect(timestampRate(`${GREEN_NOS}/rate_switches.txt`).ok).toBe(true);
  });
  test("does not mistake 'run rate=48000' lines for the timestamp rate", () => {
    expect(timestampRate(`${GREEN_OS}/rate_switches.txt`).detail).not.toContain("48000");
  });
});

describe("thread dump extraction", () => {
  const dump = [
    "Output thread 0x1, name AudioOut_8, tid 1, type 0 (MIXER):",
    "  Standby: no",
    "  Sample rate: 48000 Hz",
    "  HAL format: 0x1 (AUDIO_FORMAT_PCM_16_BIT)",
    "  Timestamp stats: n=1 disc=1 rate=nan",
    "  Threadloop write latency stats: ave=-0.1",
    "Output thread 0x2, name AudioOut_1D, tid 2, type 0 (MIXER):",
    "  Standby: no",
    "  Sample rate: 352800 Hz",
    "  HAL format: 0x3 (AUDIO_FORMAT_PCM_32_BIT)",
    "  Timestamp stats: n=15802 disc=25 rate=1.00072",
    "  Threadloop write latency stats: ave=167.8 std=0.65",
    "Output thread 0x3, name AudioOut_30, tid 3, type 2 (DIRECT):",
    "  Standby: no",
    "  Sample rate: 44100 Hz",
  ].join("\n");
  test("picks the busiest active MIXER thread, not the first one", () => {
    const out = threadDump(dump);
    expect(out[0]).toBe("Sample rate: 352800 Hz");
    expect(out[3]).toContain("ave=167.8");
  });
  test("returns nothing when no MIXER thread is active", () => {
    expect(threadDump(dump.replaceAll("Standby: no", "Standby: yes"))).toEqual([]);
  });
});

describe("log scan (patches 1, 2, 4)", () => {
  test("red: dropped-buffer and starvation lines present on v1.2", () => {
    const r = logScan(`${RED}/hal.log`);
    expect(r.ok).toBe(false);
    expect(r.detail).toMatch(/^\d+ offending lines$/);
  });
  test("green: clean in both modes", () => {
    expect(logScan(`${GREEN_OS}/hal.log`).ok).toBe(true);
    expect(logScan(`${GREEN_NOS}/hal.log`).ok).toBe(true);
  });
});
