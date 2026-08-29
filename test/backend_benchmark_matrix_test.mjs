// SPDX-License-Identifier: Apache-2.0
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  analyseRamp,
  analyseReports,
  alternatingRuns,
  bootstrapImprovement,
  buildPlan,
  buildRampPlan,
  executePlan,
  validateConfiguration,
} from "./backend_benchmark_matrix.mjs";

const input = {
  variants: [
    {
      name: "baseline",
      commands: {
        postgres: ["test/cluster_soak.sh"],
        sqlite: ["test/sqlite_soak.sh"],
      },
    },
    {
      name: "candidate",
      commands: {
        postgres: ["test/cluster_soak.sh"],
        sqlite: ["test/sqlite_soak.sh"],
      },
    },
  ],
  backends: ["postgres", "sqlite"],
  formats: ["json", "raw", "sse", "websocket"],
  scenarios: ["publish"],
  repetitions: 7,
};

test("A/B runs alternate first-mover order for seven repetitions", () => {
  assert.deepEqual(alternatingRuns(3, ["a", "b"]), [
    { repetition: 1, variant: "a" },
    { repetition: 1, variant: "b" },
    { repetition: 2, variant: "b" },
    { repetition: 2, variant: "a" },
    { repetition: 3, variant: "a" },
    { repetition: 3, variant: "b" },
  ]);
  assert.equal(alternatingRuns(7).length, 14);
});

test("bootstrap confidence interval identifies a consistent improvement", () => {
  const comparison = bootstrapImprovement(
    [21, 22, 20, 23, 21, 22, 20],
    [15, 16, 14, 17, 15, 16, 14],
    { direction: "lower", iterations: 2_000, seed: 7 },
  );
  assert.ok(comparison.improvement > 0);
  assert.ok(comparison.confidence95.lower > 0);
  assert.ok(comparison.confidence95.upper > comparison.confidence95.lower);
});

test("matrix covers both backends and all wire formats in alternating order", () => {
  const configuration = validateConfiguration(input);
  const plan = buildPlan(configuration);
  assert.equal(plan.length, 2 * 4 * 1 * 7 * 2);
  assert.deepEqual(plan.slice(0, 4).map((run) => run.variant), [
    "baseline",
    "candidate",
    "candidate",
    "baseline",
  ]);
  assert.throws(
    () => validateConfiguration({ ...input, repetitions: 6 }),
    /at least 7/,
  );
});

test("final plan is candidate-only, 600 seconds, and at least three runs", () => {
  const configuration = validateConfiguration(
    { ...input, backends: ["sqlite"], formats: ["json"] },
    { final: true },
  );
  const plan = buildPlan(configuration, { final: true });
  assert.equal(configuration.durationSeconds, 600);
  assert.equal(plan.length, 3);
  assert.ok(plan.every((run) => run.variant === "candidate"));
});

test("comparisons remain isolated by backend, format, and scenario", () => {
  const report = (backend, variant, rate) => ({
    backend,
    format: "json",
    scenario: "publish",
    variant,
    commandSucceeded: true,
    report: {
      preliminaryVerdict: { passed: true },
      publishes: { achievedRate: rate },
      deliveries: { missing: 0, duplicates: 0, orderMismatches: 0 },
    },
  });
  const analysis = analyseReports(
    [
      report("postgres", "baseline", 500),
      report("postgres", "baseline", 500),
      report("postgres", "candidate", 450),
      report("postgres", "candidate", 450),
      report("sqlite", "baseline", 300),
      report("sqlite", "baseline", 300),
      report("sqlite", "candidate", 350),
      report("sqlite", "candidate", 350),
    ],
    ["baseline", "candidate"],
  );
  const rates = analysis.comparisons.filter(
    (comparison) => comparison.metric === "publish_rate",
  );
  assert.equal(rates.length, 2);
  assert.equal(
    rates.find((comparison) => comparison.backend === "postgres")
      .statisticallyRegressed,
    true,
  );
  assert.equal(
    rates.find((comparison) => comparison.backend === "sqlite")
      .statisticallyImproved,
    true,
  );
});

test("ramp stops are analysable and must exceed the 500 publish/s baseline", () => {
  const configuration = validateConfiguration(
    {
      ...input,
      backends: ["sqlite"],
      formats: ["json"],
      rampRates: [500, 600, 750],
    },
    { ramp: true },
  );
  assert.deepEqual(
    buildRampPlan(configuration).map((run) => run.publishRate),
    [500, 600, 750],
  );
  const report = (publishRate, passed, achievedRate) => ({
    backend: "sqlite",
    format: "json",
    scenario: "publish",
    variant: "candidate",
    publishRate,
    commandSucceeded: passed,
    report: {
      preliminaryVerdict: { passed },
      publishes: {
        achievedRate,
        commitLatencyMs: { p95: passed ? 100 : 250 },
      },
      deliveries: { missing: 0, duplicates: 0, orderMismatches: 0 },
    },
  });
  const analysis = analyseRamp(
    [report(500, true, 500), report(600, true, 600), report(750, false, 700)],
    configuration,
  );
  assert.equal(analysis.passed, true);
  assert.equal(analysis.cells[0].maximumSustainedPublishRate, 600);
});

test("executor leaves each unique report directory for the soak command to create", async () => {
  const temporary = await mkdtemp(path.join(os.tmpdir(), "notify-benchmark-"));
  try {
    const fakeCommand = [
      process.execPath,
      "-e",
      `
        const fs = require("node:fs");
        const directory = process.env.NOTIFY_SOAK_REPORT_DIRECTORY;
        if (fs.existsSync(directory)) process.exit(42);
        fs.mkdirSync(directory, { recursive: true });
        fs.writeFileSync(process.env.NOTIFY_SOAK_REPORT_PATH, JSON.stringify({
          preliminaryVerdict: { passed: true },
          publishes: { committed: 1, achievedRate: 1 },
          deliveries: { missing: 0, duplicates: 0, orderMismatches: 0 }
        }));
      `,
    ];
    const configuration = validateConfiguration({
      ...input,
      backends: ["sqlite"],
      formats: ["json"],
      scenarios: ["publish"],
      outputDirectory: path.join(temporary, "results"),
      variants: input.variants.map((variant) => ({
        ...variant,
        commands: { sqlite: fakeCommand },
      })),
    });
    const reports = await executePlan(configuration, [
      {
        backend: "sqlite",
        format: "json",
        scenario: "publish",
        repetition: 1,
        variant: "candidate",
      },
    ]);
    assert.equal(reports.length, 1);
    assert.equal(reports[0].commandSucceeded, true);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});
