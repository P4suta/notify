// SPDX-License-Identifier: Apache-2.0
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const publicDirectory = path.join(root, "priv", "public");

async function readJson(name) {
  return JSON.parse(await readFile(path.join(publicDirectory, name), "utf8"));
}

async function pngDimensions(name) {
  const bytes = await readFile(path.join(publicDirectory, name));
  assert.deepEqual(
    bytes.subarray(0, 8),
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    `${name} must be a PNG`,
  );
  assert.equal(bytes.subarray(12, 16).toString("ascii"), "IHDR");
  return [bytes.readUInt32BE(16), bytes.readUInt32BE(20)];
}

test("manifest has stable install identity and raster icon fallbacks", async () => {
  const manifest = await readJson("manifest.webmanifest");
  assert.equal(manifest.id, "/");
  assert.equal(manifest.scope, "/");
  assert.equal(manifest.start_url, "/");
  assert.equal(manifest.display, "standalone");

  const icons = new Map(manifest.icons.map((icon) => [icon.sizes, icon]));
  const icon192 = icons.get("192x192");
  const icon512 = icons.get("512x512");
  const iconScalable = icons.get("any");
  assert.deepEqual(icon192, {
    src: "/icon-192.png",
    sizes: "192x192",
    type: "image/png",
    purpose: "any",
  });
  assert.deepEqual(icon512, {
    src: "/icon-512.png",
    sizes: "512x512",
    type: "image/png",
    purpose: "any maskable",
  });
  assert.deepEqual(iconScalable, {
    src: "/icon.svg",
    sizes: "any",
    type: "image/svg+xml",
    purpose: "any",
  });
  assert.deepEqual(await pngDimensions("icon-192.png"), [192, 192]);
  assert.deepEqual(await pngDimensions("icon-512.png"), [512, 512]);
});

test("offline shell precaches install assets and falls back for navigation", async () => {
  const worker = await readFile(path.join(publicDirectory, "sw.js"), "utf8");
  for (const asset of [
    "/",
    "/styles.css",
    "/notify_web.js",
    "/manifest.webmanifest",
    "/icon.svg",
    "/icon-192.png",
    "/icon-512.png",
  ]) {
    assert.ok(worker.includes(`'${asset}'`), `${asset} must be precached`);
  }
  assert.match(worker, /event\.request\.mode\s*===\s*['"]navigate['"]/);
  assert.match(worker, /caches\.match\(['"]\/['"]\)/);
});
