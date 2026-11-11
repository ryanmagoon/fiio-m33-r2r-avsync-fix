// Offline consistency checks on the installer's data: the byte-patch specs and the SHA-256
// table. They cannot prove a patch is right (only tools/regression.sh on the device can);
// they catch a mistyped spec or a README that has drifted from module/customize.sh.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const installer = readFileSync("module/customize.sh", "utf8");
const readme = readFileSync("README.md", "utf8");

test("every OFF:OLD:NEW spec replaces whole bytes with the same number of bytes", () => {
  const specs = [...installer.matchAll(/\b0x[0-9a-f]+:([0-9a-f]*):([0-9a-f]*)/g)];
  expect(specs.length).toBeGreaterThan(0);
  for (const [spec, oldBytes, newBytes] of specs) {
    expect(oldBytes.length % 2, `odd number of hex digits in ${spec}`).toBe(0);
    expect(newBytes.length, `OLD and NEW differ in length in ${spec}`).toBe(oldBytes.length);
  }
});

test("README hash table matches the stock and patched hashes in customize.sh", () => {
  const fromInstaller = [
    ...installer.matchAll(/^do_patch "[^"]+" (\S+) \S+ \\\n\s*([0-9a-f]{64}) \\\n\s*([0-9a-f]{64}) /gm),
  ].map(([, path, stock, patched]) => ({ path, stock, patched }));
  const fromReadme = [
    ...readme.matchAll(/^\| `([^`]+)` \| `([0-9a-f]{64})` \| `([0-9a-f]{64})` \|$/gm),
  ].map(([, path, stock, patched]) => ({ path, stock, patched }));
  expect(fromInstaller.length).toBe(installer.match(/^do_patch /gm)?.length ?? 0);
  expect(fromInstaller.length).toBeGreaterThan(0);
  expect(fromReadme).toEqual(fromInstaller);
});
