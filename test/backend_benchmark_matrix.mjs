#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const defaultBackends = ["postgres", "sqlite"];
const defaultFormats = ["json", "raw", "sse", "websocket"];
const defaultScenarios = [
  "publish",
  "webpush-relay",
  "scheduled",
  "slow-provider",
  "attachments",
];

const metrics = [
  { name: "publish_rate", path: "publishes.achievedRate", direction: "higher" },
  { name: "commit_p50_ms", path: "publishes.commitLatencyMs.p50", direction: "lower" },
  { name: "commit_p95_ms", path: "publishes.commitLatencyMs.p95", direction: "lower" },
  { name: "commit_p99_ms", path: "publishes.commitLatencyMs.p99", direction: "lower" },
  { name: "delivery_p95_ms", path: "deliveries.afterCommitLatencyMs.p95", direction: "lower" },
  { name: "driver_cpu_us_per_publish", path: "driverResources.cpuMicrosecondsPerPublish", direction: "lower" },
  { name: "driver_peak_rss_bytes", path: "driverResources.peakRssBytes", direction: "lower" },
  { name: "server_cpu_us_per_publish", path: "serverResources.cpu_usec_per_publish", direction: "lower" },
  { name: "server_peak_rss_bytes", path: "serverResources.aggregate_memory_peak_bytes", direction: "lower" },
  { name: "beam_run_queue", path: "serverResources.beam_run_queue", direction: "lower" },
  { name: "beam_mailbox_messages", path: "serverResources.beam_mailbox_messages", direction: "lower" },
  { name: "beam_max_mailbox_messages", path: "serverResources.beam_max_mailbox_messages", direction: "lower" },
  { name: "scheduler_delay_ms", path: "serverResources.scheduler_delay_milliseconds", direction: "lower" },
  { name: "db_statements_per_publish", path: "databaseResources.statements_per_publish", direction: "lower" },
  { name: "db_transactions_per_publish", path: "databaseResources.transactions_per_publish", direction: "lower" },
];

export function alternatingRuns(repetitions, variants = ["baseline", "candidate"]) {
  if (!Number.isSafeInteger(repetitions) || repetitions < 1) {
    throw new Error("repetitions must be a positive integer");
  }
  if (variants.length !== 2 || variants[0] === variants[1]) {
    throw new Error("A/B runs require two distinct variants");
  }
  const runs = [];
  for (let repetition = 0; repetition < repetitions; repetition += 1) {
    const order = repetition % 2 === 0 ? variants : [...variants].reverse();
    for (const variant of order) runs.push({ repetition: repetition + 1, variant });
  }
  return runs;
}

function randomGenerator(seed) {
  let state = seed >>> 0;
  return () => {
    state += 0x6d2b79f5;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296;
  };
}

function mean(values) {
  return values.reduce((total, value) => total + value, 0) / values.length;
}

function quantile(sorted, fraction) {
  if (sorted.length === 0) return null;
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)];
}

export function bootstrapImprovement(
  baseline,
  candidate,
  { direction = "lower", iterations = 10_000, seed = 0x4e4f5449 } = {},
) {
  if (baseline.length < 2 || candidate.length < 2) {
    throw new Error("bootstrap comparison requires at least two samples per variant");
  }
  if (!["lower", "higher"].includes(direction)) {
    throw new Error("direction must be lower or higher");
  }
  const improvement = (baselineMean, candidateMean) =>
    direction === "lower"
      ? baselineMean - candidateMean
      : candidateMean - baselineMean;
  const random = randomGenerator(seed);
  const samples = [];
  for (let iteration = 0; iteration < iterations; iteration += 1) {
    const sampledBaseline = [];
    const sampledCandidate = [];
    for (let index = 0; index < baseline.length; index += 1) {
      sampledBaseline.push(baseline[Math.floor(random() * baseline.length)]);
    }
    for (let index = 0; index < candidate.length; index += 1) {
      sampledCandidate.push(candidate[Math.floor(random() * candidate.length)]);
    }
    samples.push(improvement(mean(sampledBaseline), mean(sampledCandidate)));
  }
  samples.sort((left, right) => left - right);
  return {
    baselineMean: mean(baseline),
    candidateMean: mean(candidate),
    improvement: improvement(mean(baseline), mean(candidate)),
    confidence95: {
      lower: quantile(samples, 0.025),
      upper: quantile(samples, 0.975),
    },
  };
}

function valueAt(object, dottedPath) {
  return dottedPath.split(".").reduce((value, key) => value?.[key], object);
}

export function analyseReports(reports, variantNames) {
  const comparisons = [];
  const cells = new Map();
  for (const report of reports) {
    const key = [report.backend, report.format, report.scenario].join("\0");
    if (!cells.has(key)) {
      cells.set(key, {
        backend: report.backend,
        format: report.format,
        scenario: report.scenario,
        reports: [],
      });
    }
    cells.get(key).reports.push(report);
  }
  for (const cell of cells.values()) {
    for (const metric of metrics) {
      const baseline = cell.reports
        .filter((report) => report.variant === variantNames[0])
        .map((report) => valueAt(report.report, metric.path))
        .filter(Number.isFinite);
      const candidate = cell.reports
        .filter((report) => report.variant === variantNames[1])
        .map((report) => valueAt(report.report, metric.path))
        .filter(Number.isFinite);
      if (baseline.length < 2 || candidate.length < 2) continue;
      const comparison = bootstrapImprovement(baseline, candidate, {
        direction: metric.direction,
      });
      comparisons.push({
        backend: cell.backend,
        format: cell.format,
        scenario: cell.scenario,
        metric: metric.name,
        direction: metric.direction,
        samples: { baseline: baseline.length, candidate: candidate.length },
        ...comparison,
        statisticallyImproved: comparison.confidence95.lower > 0,
        statisticallyRegressed: comparison.confidence95.upper < 0,
      });
    }
  }
  const correctnessPassed = reports.every(({ commandSucceeded, report }) =>
    commandSucceeded !== false &&
    (report.verdict?.passed ?? report.preliminaryVerdict?.passed) === true &&
    report.deliveries?.missing === 0 &&
    report.deliveries?.duplicates === 0 &&
    report.deliveries?.orderMismatches === 0
  );
  return {
    correctnessPassed,
    protectedMetricsRegressed: comparisons.some(
      (comparison) => comparison.statisticallyRegressed,
    ),
    comparisons,
  };
}

function stringArray(value, fallback, name) {
  const selected = value ?? fallback;
  if (!Array.isArray(selected) || selected.length === 0) {
    throw new Error(`${name} must be a non-empty array`);
  }
  if (!selected.every((item) => typeof item === "string" && item.length > 0)) {
    throw new Error(`${name} must contain non-empty strings`);
  }
  return selected;
}

function supportedStringArray(value, fallback, name, supported) {
  const selected = stringArray(value, fallback, name);
  for (const item of selected) {
    if (!supported.includes(item)) {
      throw new Error(`unsupported ${name.slice(0, -1)}: ${item}`);
    }
  }
  return selected;
}

function positiveInteger(value, fallback, name) {
  const selected = value ?? fallback;
  if (!Number.isSafeInteger(selected) || selected < 1) {
    throw new Error(`${name} must be a positive integer`);
  }
  return selected;
}

function increasingRates(value) {
  const rates = value ?? [500, 600, 750, 1_000, 1_250, 1_500, 2_000];
  if (
    !Array.isArray(rates) ||
    rates.length < 2 ||
    !rates.every((rate) => Number.isSafeInteger(rate) && rate > 0)
  ) {
    throw new Error("rampRates must contain at least two positive integers");
  }
  for (let index = 1; index < rates.length; index += 1) {
    if (rates[index] <= rates[index - 1]) {
      throw new Error("rampRates must be strictly increasing");
    }
  }
  return rates;
}

export function validateConfiguration(
  input,
  { final = false, ramp = false } = {},
) {
  if (!input || typeof input !== "object") {
    throw new Error("configuration must be an object");
  }
  if (final && ramp) throw new Error("--final and --ramp are mutually exclusive");
  if (!Array.isArray(input.variants) || input.variants.length !== 2) {
    throw new Error("configuration must define baseline and candidate variants");
  }
  const variants = input.variants.map((variant) => {
    if (!variant || typeof variant.name !== "string" || !variant.commands) {
      throw new Error("each variant requires a name and backend commands");
    }
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(variant.name)) {
      throw new Error("variant names must be safe path components");
    }
    const commands = Object.fromEntries(
      Object.entries(variant.commands).map(([backend, command]) => {
        if (
          !Array.isArray(command) ||
          !command.every((part) => typeof part === "string") ||
          command.length === 0
        ) {
          throw new Error(`variant ${variant.name} command for ${backend} must be an argument array`);
        }
        return [backend, command];
      }),
    );
    const environment = variant.environment ?? {};
    if (
      !environment ||
      typeof environment !== "object" ||
      Array.isArray(environment) ||
      !Object.values(environment).every((value) => typeof value === "string")
    ) {
      throw new Error(`variant ${variant.name} environment must contain strings`);
    }
    return { name: variant.name, commands, environment };
  });
  if (variants[0].name === variants[1].name) {
    throw new Error("variant names must differ");
  }
  const repetitions = final ? 3 : ramp ? 1 : (input.repetitions ?? 7);
  if (!Number.isSafeInteger(repetitions) || repetitions < (final ? 3 : 7)) {
    if (!ramp) {
      throw new Error(
        final
          ? "final repetitions must be at least 3"
          : "A/B repetitions must be at least 7",
      );
    }
  }
  const backends = stringArray(input.backends, defaultBackends, "backends");
  for (const backend of backends) {
    if (!defaultBackends.includes(backend)) throw new Error(`unsupported backend: ${backend}`);
    for (const variant of variants) {
      if (!variant.commands[backend]) {
        throw new Error(`variant ${variant.name} has no ${backend} command`);
      }
    }
  }
  const formats = supportedStringArray(
    input.formats,
    defaultFormats,
    "formats",
    defaultFormats,
  );
  const scenarios = ramp
    ? ["publish"]
    : supportedStringArray(
        input.scenarios,
        defaultScenarios,
        "scenarios",
        defaultScenarios,
      );
  const rampRates = increasingRates(input.rampRates);
  const minimumSustainedPublishRate = positiveInteger(
    input.minimumSustainedPublishRate,
    500,
    "minimumSustainedPublishRate",
  );
  if (ramp && !rampRates.some((rate) => rate > minimumSustainedPublishRate)) {
    throw new Error(
      "rampRates must include a rate above minimumSustainedPublishRate",
    );
  }
  return {
    variants,
    repetitions,
    backends,
    formats,
    scenarios,
    rampRates,
    minimumSustainedPublishRate,
    durationSeconds: final
      ? 600
      : ramp
        ? positiveInteger(input.rampDurationSeconds, 30, "rampDurationSeconds")
        : positiveInteger(input.durationSeconds, 30, "durationSeconds"),
    outputDirectory: path.resolve(input.outputDirectory ?? "benchmark-results"),
  };
}

export function buildPlan(configuration, { final = false } = {}) {
  const variantNames = configuration.variants.map((variant) => variant.name);
  const order = final
    ? Array.from({ length: configuration.repetitions }, (_, index) => ({
        repetition: index + 1,
        variant: variantNames[1],
      }))
    : alternatingRuns(configuration.repetitions, variantNames);
  const plan = [];
  for (const backend of configuration.backends) {
    for (const format of configuration.formats) {
      for (const scenario of configuration.scenarios) {
        for (const run of order) plan.push({ backend, format, scenario, ...run });
      }
    }
  }
  return plan;
}

export function buildRampPlan(configuration) {
  const candidate = configuration.variants[1].name;
  const plan = [];
  for (const backend of configuration.backends) {
    for (const format of configuration.formats) {
      for (const publishRate of configuration.rampRates) {
        plan.push({
          backend,
          format,
          scenario: "publish",
          repetition: 1,
          variant: candidate,
          publishRate,
        });
      }
    }
  }
  return plan;
}

function runCommand(command, environment) {
  return new Promise((resolve, reject) => {
    const child = spawn(command[0], command.slice(1), {
      cwd: process.cwd(),
      env: { ...process.env, ...environment },
      stdio: "inherit",
      shell: false,
    });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      resolve({
        succeeded: code === 0,
        code,
        signal,
        detail: code === 0 ? null : `benchmark command exited with ${signal ?? code}`,
      });
    });
  });
}

function reportCorrect(report) {
  return (
    (report.verdict?.passed ?? report.preliminaryVerdict?.passed) === true &&
    report.deliveries?.missing === 0 &&
    report.deliveries?.duplicates === 0 &&
    report.deliveries?.orderMismatches === 0
  );
}

export function analyseRamp(reports, configuration) {
  const cells = [];
  for (const backend of configuration.backends) {
    for (const format of configuration.formats) {
      const attempted = reports
        .filter((report) => report.backend === backend && report.format === format)
        .sort((left, right) => left.publishRate - right.publishRate);
      const sustainable = attempted.filter(
        ({ commandSucceeded, publishRate, report }) =>
          commandSucceeded &&
          reportCorrect(report) &&
          report.publishes?.achievedRate >= publishRate * 0.99,
      );
      const maximumSustainedPublishRate = sustainable.length === 0
        ? null
        : Math.max(...sustainable.map((report) => report.publishRate));
      cells.push({
        backend,
        format,
        minimumSustainedPublishRate: configuration.minimumSustainedPublishRate,
        maximumSustainedPublishRate,
        exceededMinimum:
          maximumSustainedPublishRate !== null &&
          maximumSustainedPublishRate > configuration.minimumSustainedPublishRate,
        attempts: attempted.map(({ publishRate, commandSucceeded, report }) => ({
          publishRate,
          commandSucceeded,
          correctnessPassed: reportCorrect(report),
          achievedRate: report.publishes?.achievedRate ?? null,
          commitP95Ms: report.publishes?.commitLatencyMs?.p95 ?? null,
        })),
      });
    }
  }
  return {
    passed: cells.length > 0 && cells.every((cell) => cell.exceededMinimum),
    cells,
  };
}

export async function executePlan(configuration, plan, { ramp = false } = {}) {
  await mkdir(configuration.outputDirectory, { recursive: false });
  const collected = [];
  const saturatedCells = new Set();
  for (let index = 0; index < plan.length; index += 1) {
    const run = plan[index];
    const cell = `${run.backend}\0${run.format}`;
    if (ramp && saturatedCells.has(cell)) continue;
    const variant = configuration.variants.find((item) => item.name === run.variant);
    const runName = [
      String(index + 1).padStart(4, "0"),
      run.backend,
      run.format,
      run.scenario,
      run.variant,
      `r${run.repetition}`,
      ...(run.publishRate ? [`rate-${run.publishRate}`] : []),
    ].join("-");
    const runDirectory = path.join(configuration.outputDirectory, runName);
    const reportPath = path.join(runDirectory, "report.json");
    const command = await runCommand(variant.commands[run.backend], {
      ...variant.environment,
      NOTIFY_SOAK_BACKEND: run.backend,
      NOTIFY_SOAK_FORMAT: run.format,
      NOTIFY_BENCHMARK_SCENARIO: run.scenario,
      NOTIFY_SOAK_DURATION_SECONDS: String(configuration.durationSeconds),
      NOTIFY_SOAK_REPORT_DIRECTORY: runDirectory,
      NOTIFY_SOAK_REPORT_PATH: reportPath,
      ...(run.publishRate
        ? { NOTIFY_SOAK_PUBLISH_RATE: String(run.publishRate) }
        : {}),
    });
    let encoded;
    try {
      encoded = await readFile(reportPath, "utf8");
    } catch (error) {
      throw new Error(
        `${command.detail ?? "benchmark command did not produce a report"}: ${error.message}`,
      );
    }
    const report = JSON.parse(encoded);
    try {
      report.serverResources = JSON.parse(
        await readFile(path.join(runDirectory, "server-resources.json"), "utf8"),
      );
    } catch {
      report.serverResources = null;
    }
    try {
      const database = JSON.parse(
        await readFile(path.join(runDirectory, "database.json"), "utf8"),
      );
      const committed = report.publishes?.committed ?? 0;
      const transactions =
        (database.transactions_committed ?? 0) +
        (database.transactions_rolled_back ?? 0);
      report.databaseResources = {
        ...database,
        statements_per_publish:
          committed > 0 ? database.statements / committed : null,
        transactions_per_publish:
          committed > 0 ? transactions / committed : null,
      };
    } catch {
      report.databaseResources = null;
    }
    const record = {
      ...run,
      reportPath,
      commandSucceeded: command.succeeded,
      commandExitCode: command.code,
      commandSignal: command.signal,
      report,
    };
    collected.push(record);
    await writeFile(
      path.join(configuration.outputDirectory, "runs.json"),
      `${JSON.stringify(collected, null, 2)}\n`,
      { mode: 0o600 },
    );
    if (!command.succeeded || !reportCorrect(report)) {
      if (ramp) saturatedCells.add(cell);
      else throw new Error(command.detail ?? "benchmark correctness failed");
    }
  }
  return collected;
}

async function main() {
  const args = process.argv.slice(2);
  const final = args.includes("--final");
  const ramp = args.includes("--ramp");
  const planOnly = args.includes("--plan");
  const configPath = args.find((argument) => !argument.startsWith("--"));
  if (!configPath) {
    throw new Error(
      "usage: backend_benchmark_matrix.mjs <config.json> [--plan] [--final|--ramp]",
    );
  }
  const input = JSON.parse(await readFile(path.resolve(configPath), "utf8"));
  const configuration = validateConfiguration(input, { final, ramp });
  const plan = ramp
    ? buildRampPlan(configuration)
    : buildPlan(configuration, { final });
  if (planOnly) {
    process.stdout.write(`${JSON.stringify(plan, null, 2)}\n`);
    return;
  }
  const reports = await executePlan(configuration, plan, { ramp });
  const analysis = ramp
    ? analyseRamp(reports, configuration)
    : analyseReports(
        reports,
        configuration.variants.map((variant) => variant.name),
      );
  await writeFile(
    path.join(configuration.outputDirectory, "analysis.json"),
    `${JSON.stringify(analysis, null, 2)}\n`,
    { mode: 0o600 },
  );
  process.stdout.write(`${JSON.stringify(analysis, null, 2)}\n`);
  if (
    ramp
      ? !analysis.passed
      : !analysis.correctnessPassed || analysis.protectedMetricsRegressed
  ) {
    process.exitCode = 1;
  }
}

const invokedPath = process.argv[1]
  ? pathToFileURL(path.resolve(process.argv[1])).href
  : "";
if (import.meta.url === invokedPath) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
