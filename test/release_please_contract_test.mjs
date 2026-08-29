// SPDX-License-Identifier: Apache-2.0
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const files = {
  config: new URL("../release-please-config.json", import.meta.url),
  manifest: new URL("../.release-please-manifest.json", import.meta.url),
  workflow: new URL(
    "../.github/workflows/release-please.yml",
    import.meta.url,
  ),
  rootGleam: new URL("../gleam.toml", import.meta.url),
  rootManifest: new URL("../manifest.toml", import.meta.url),
  rootMix: new URL("../mix.exs", import.meta.url),
  coreGleam: new URL("../packages/notify_core/gleam.toml", import.meta.url),
  coreMix: new URL("../packages/notify_core/mix.exs", import.meta.url),
  webGleam: new URL("../web/gleam.toml", import.meta.url),
};

const tomlVersion = (contents) =>
  contents.match(/^version = "([^"]+)"$/m)?.[1];
const mixVersion = (contents) =>
  contents.match(/^\s+version: "([^"]+)",/m)?.[1];
const lockedCoreVersion = (contents) =>
  contents.match(
    /\{ name = "notify_core", version = "([^"]+)"[^\n]+source = "local"/,
  )?.[1];

test("release-please uses a pinned action with least required write access", async () => {
  const workflow = await readFile(files.workflow, "utf8");
  assert.match(workflow, /push:\n\s+branches:\n\s+- main/);
  assert.match(workflow, /contents: write/);
  assert.match(workflow, /issues: write/);
  assert.match(workflow, /pull-requests: write/);
  assert.match(
    workflow,
    /googleapis\/release-please-action@5c625bfb5d1ff62eadeeb3772007f7f66fdcf071 # v4\.4\.1/,
  );
  assert.match(
    workflow,
    /secrets\.RELEASE_PLEASE_TOKEN \|\| github\.token/,
  );
  assert.doesNotMatch(workflow, /pull_request_target/);
});

test("one manifest release updates every bundled project version", async () => {
  const config = JSON.parse(await readFile(files.config, "utf8"));
  const manifest = JSON.parse(await readFile(files.manifest, "utf8"));
  assert.equal(config["release-type"], "elixir");
  assert.equal(config["include-component-in-tag"], false);
  assert.equal(config["include-v-in-tag"], true);
  assert.equal(
    config["bootstrap-sha"],
    "8e1830adfb31df147c48c3349023bf327ae9b114",
  );

  const packageConfig = config.packages["."];
  assert.equal(packageConfig["initial-version"], "0.1.0");
  const releasedVersion = manifest["."];
  if (releasedVersion === undefined) {
    assert.deepEqual(manifest, {});
  } else {
    assert.match(releasedVersion, /^\d+\.\d+\.\d+$/);
    assert.deepEqual(Object.keys(manifest), ["."]);
  }
  const projectVersion = releasedVersion ?? packageConfig["initial-version"];

  const extraFiles = packageConfig["extra-files"];
  assert.deepEqual(
    extraFiles.map(({ path }) => path),
    [
      "gleam.toml",
      "packages/notify_core/gleam.toml",
      "manifest.toml",
      "packages/notify_core/mix.exs",
      "web/gleam.toml",
    ],
  );
  assert.deepEqual(
    extraFiles.find(({ path }) => path === "manifest.toml"),
    {
      type: "toml",
      path: "manifest.toml",
      jsonpath: "$.packages[?(@.name == 'notify_core')].version",
    },
  );

  const contents = await Promise.all([
    readFile(files.rootGleam, "utf8"),
    readFile(files.rootManifest, "utf8"),
    readFile(files.rootMix, "utf8"),
    readFile(files.coreGleam, "utf8"),
    readFile(files.coreMix, "utf8"),
    readFile(files.webGleam, "utf8"),
  ]);
  assert.deepEqual(
    [
      tomlVersion(contents[0]),
      lockedCoreVersion(contents[1]),
      mixVersion(contents[2]),
      tomlVersion(contents[3]),
      mixVersion(contents[4]),
      tomlVersion(contents[5]),
    ],
    Array(6).fill(projectVersion),
  );
  assert.match(
    contents[4],
    new RegExp(
      `version: "${projectVersion.replaceAll(".", "\\.")}", # x-release-please-version`,
    ),
  );
});
