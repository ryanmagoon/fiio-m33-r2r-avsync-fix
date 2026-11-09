# Project rules for people and coding agents

These apply to every change in this repository, by a person or an agent.

## Validation gate

- No module version is released, and no patch is added or changed, without a committed run of
  `tools/regression.sh` that was **red on the previous build and green on the new one**, in
  both OS and NOS mode. The two output folders go in `logs/regression-<version>-{os,nos}/`
  (green) and the red run's `summary.txt` and the failing check's log in
  `logs/regression-<version>-red/`.
- A new defect gets its check added to `tools/regression.sh` **before** the patch is written,
  and the check must fail on the unpatched build. Ad hoc shell loops in a terminal do not count
  as validation.
- The checks live in `tools/checks.ts` and are covered by `bun test` (`tools/checks.test.ts`),
  which replays the committed red and green fixtures offline. Run it before every commit.
- Tooling and tests are TypeScript on Bun. No Python unless there is no reasonable alternative.

## Device safety

- Never read anything under `/sys/devices/platform/soc/soc:fiio_attr/`; it crashes the kernel.
- Never flash a partition other than `init_boot`, and never publish firmware images, FiiO
  binaries, or anything from a device backup.
- Published logs contain `TSPROBE` lines, HAL excerpts and `dumpsys` thread excerpts only;
  strip pids, serial numbers, board numbers, SSIDs and account names.

## Working on the device

- `adb shell su -c 'a; b'` runs only `a` as root on this device: push a script and run
  `su -c "sh /data/local/tmp/x.sh"`.
- The OS/NOS switch is Settings > Audio > PCM OUT MODE; uiautomator can drive it.
- Installer byte checks must use `od -v`.
