#!/usr/bin/env bun
// Pass/fail checks used by tools/regression.sh, kept separate so they can be unit-tested
// offline against the committed red/green fixtures in logs/ (see checks.test.ts).
//
//   bun run tools/checks.ts pause   logs/.../pause_cycles_48000.log [tolMs]
//   bun run tools/checks.ts track   logs/.../new_track_48000.log    [tolMs]
//   bun run tools/checks.ts switch  logs/.../rate_switches.txt      [tolMs]
//   bun run tools/checks.ts tsrate  logs/.../rate_switches.txt
//   bun run tools/checks.ts logscan logs/.../hal.log
//
// Prints "PASS <detail>" or "FAIL <detail>"; exit status 0 only on PASS.
import { readFileSync } from "node:fs";

export const TOL_MS = 5;
/** queued_ms samples the client buffer once a second and jitters a few ms at 44.1 kHz in NOS;
 *  the defect it guards against (patch 1) moved it by a whole buffer fill, ~230 ms per cycle. */
export const QUEUED_TOL_MS = 10;

export type CheckResult = { ok: boolean; detail: string };

const lines = (path: string): string[] => readFileSync(path, "utf8").split("\n");
const spread = (xs: number[]): number => Math.max(...xs) - Math.min(...xs);

/** queued_ms and head_minus_ts_ms must be constant across pause/resume cycles
 *  (patch 1; also patch 4 at 44.1 kHz, where every resume restarts the processing thread). */
export function pauseCycles(path: string, tolMs = TOL_MS): CheckResult {
  const perCycle = new Map<number, { queued: number; head: number }[]>();
  for (const ln of lines(path)) {
    const m = /t=[\d.]+ cycles=(\d+) paused=false .*queued_ms=(\d+) ts_ok=true .*head_minus_ts_ms=(-?\d+)/.exec(ln);
    if (!m) continue;
    const cycle = Number(m[1]);
    const rows = perCycle.get(cycle) ?? [];
    rows.push({ queued: Number(m[2]), head: Number(m[3]) });
    perCycle.set(cycle, rows);
  }
  // steady sample at the end of each cycle; cycles with fewer than three samples are transients
  const last = [...perCycle.entries()]
    .sort((a, b) => a[0] - b[0])
    .filter(([, rows]) => rows.length >= 3)
    .map(([, rows]) => rows[rows.length - 1]);
  if (last.length < 4) return { ok: false, detail: `only ${last.length} usable cycles` };
  const q = last.map((r) => r.queued);
  const h = last.map((r) => r.head);
  return {
    ok: spread(q) <= Math.max(tolMs, QUEUED_TOL_MS) && spread(h) <= tolMs,
    detail: `queued_ms=[${q}] head_minus_ts_ms=[${h}]`,
  };
}

/** head_minus_ts_ms must be identical on every freshly created track (patch 2). */
export function newTrack(path: string, tolMs = TOL_MS): CheckResult {
  const perTrack = new Map<number, number[]>();
  for (const ln of lines(path)) {
    const m = /TRACK (\d+) age=([\d.]+) .*ts_ok=true .*head_minus_ts_ms=(-?\d+)/.exec(ln);
    if (!m || Number(m[2]) < 3) continue; // first seconds of a track are start-up transient
    const track = Number(m[1]);
    perTrack.set(track, [...(perTrack.get(track) ?? []), Number(m[3])]);
  }
  const h = [...perTrack.entries()].sort((a, b) => a[0] - b[0]).map(([, v]) => v[v.length - 1]);
  if (h.length < 6) return { ok: false, detail: `only ${h.length} tracks measured` };
  return { ok: spread(h) <= tolMs, detail: `head_minus_ts_ms per track=[${h}]` };
}

type SwitchRows = { latency: number[]; disc: number[]; rates: number[]; tsRate: number[] };

function switchRows(path: string): SwitchRows {
  const out: SwitchRows = { latency: [], disc: [], rates: [], tsRate: [] };
  for (const ln of lines(path)) {
    let m = /write latency stats: ave=([\d.]+)/.exec(ln);
    if (m) out.latency.push(Number(m[1]));
    m = /disc=(\d+)/.exec(ln);
    if (m) out.disc.push(Number(m[1]));
    m = /Sample rate: (\d+)/.exec(ln);
    if (m) out.rates.push(Number(m[1]));
    m = /Timestamp stats:.*\brate=([\d.]+)/.exec(ln);
    if (m) out.tsRate.push(Number(m[1]));
  }
  return out;
}

/** Thread write latency must not move across ten hardware rate switches (patch 4).
 *  Runs are compared within the same thread rate: in NOS the thread runs at the track rate,
 *  so one buffer is legitimately 8.8% longer in ms at 44.1 kHz than at 48 kHz. */
export function rateSwitches(path: string, tolMs = TOL_MS): CheckResult {
  const { latency, disc, rates } = switchRows(path);
  if (latency.length < 10 || rates.length !== latency.length) {
    return { ok: false, detail: `only ${latency.length} latency samples` };
  }
  const byRate = new Map<number, number[]>();
  rates.forEach((r, i) => byRate.set(r, [...(byRate.get(r) ?? []), latency[i]]));
  const maxSpread = Math.max(...[...byRate.values()].map(spread));
  const discIncrements = disc.every((d, i) => i === 0 || d > disc[i - 1]);
  const summary = [...byRate.entries()].map(([r, v]) => `${r}:[${v.map((x) => x.toFixed(1))}]`).join(" ");
  return {
    ok: maxSpread <= tolMs && discIncrements && byRate.size === 2,
    detail: `latency_ms ${summary} max_spread_at_same_rate=${maxSpread.toFixed(1)} disc=[${disc}]`,
  };
}

/** AudioFlinger's timestamp rate must be 0.99..1.03 (patch 3; stock NOS reads about 2.0). */
export function timestampRate(path: string): CheckResult {
  const { tsRate } = switchRows(path);
  return {
    ok: tsRate.length > 0 && tsRate.every((x) => x >= 0.99 && x <= 1.03),
    detail: `rate=[${tsRate}]`,
  };
}

const OFFENDING = /goto create retrack|no more data to write|Insufficient audio processing efficiency/;

/** No retrack, dropped-buffer or starvation lines anywhere in the suite (patches 1, 2, 4). */
export function logScan(path: string): CheckResult {
  const n = lines(path).filter((ln) => OFFENDING.test(ln)).length;
  return { ok: n === 0, detail: n === 0 ? "no offending lines" : `${n} offending lines` };
}

/** Extracts the key lines of the active MIXER output thread from a `dumpsys media.audio_flinger` dump. */
export function threadDump(dump: string): string[] {
  const keys = ["Sample rate", "HAL format", "Timestamp stats", "Threadloop write latency"];
  // several MIXER threads can be out of standby (system sounds, telephony); the one playing
  // the probe is the one with the most timestamps taken
  const active = dump
    .split(/\n(?=Output thread )/)
    .filter((b) => b.includes("Standby: no") && b.includes("(MIXER)"))
    .map((b) => ({ b, n: Number(/Timestamp stats: n=(\d+)/.exec(b)?.[1] ?? 0) }))
    .sort((x, y) => y.n - x.n)[0];
  if (!active) return [];
  return keys.flatMap((k) => {
    const m = new RegExp(`^\\s*${k}.*$`, "m").exec(active.b);
    return m ? [m[0].trim().slice(0, 160)] : [];
  });
}

export const CHECKS: Record<string, (file: string, tol?: number) => CheckResult> = {
  pause: pauseCycles,
  track: newTrack,
  switch: rateSwitches,
  tsrate: timestampRate,
  logscan: logScan,
};

if (import.meta.main) {
  const [name, file, tol] = process.argv.slice(2);
  if (name === "threaddump") {
    console.log(threadDump(readFileSync(0, "utf8")).join("\n"));
    process.exit(0);
  }
  const check = name ? CHECKS[name] : undefined;
  if (!check || !file) {
    console.error("usage: checks.ts <pause|track|switch|tsrate|logscan> <file> [tolMs]");
    process.exit(2);
  }
  const { ok, detail } = check(file, tol ? Number(tol) : undefined);
  console.log(`${ok ? "PASS" : "FAIL"} ${detail}`);
  process.exit(ok ? 0 : 1);
}
