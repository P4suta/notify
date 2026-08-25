#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

import { evaluateReport } from "./cluster_soak.mjs";

const messageIdPattern = /^[A-Za-z0-9]{12}$/;
const topicPattern = /^[-_A-Za-z0-9]{1,64}$/;
const maximumExamples = 100;
const expectedClusterNodes = ["notify-a", "notify-b", "notify-c"];

function addExample(examples, detail) {
  if (examples.length < maximumExamples) examples.push(detail);
}

export function validateDurableSequences(expectedByTopic, observedByTopic) {
  let eventsExpected = 0;
  let eventsObserved = 0;
  let sequenceMismatches = 0;
  const examples = [];

  for (const messageIds of expectedByTopic.values()) {
    eventsExpected += messageIds.length;
  }
  for (const messageIds of observedByTopic.values()) {
    eventsObserved += messageIds.length;
  }

  const topics = new Set([
    ...expectedByTopic.keys(),
    ...observedByTopic.keys(),
  ]);
  for (const topic of topics) {
    const expected = expectedByTopic.get(topic);
    const observed = observedByTopic.get(topic);
    if (
      expected === undefined ||
      observed === undefined ||
      expected.length !== observed.length ||
      expected.some((id, index) => id !== observed[index])
    ) {
      sequenceMismatches += 1;
      let firstDifference = 0;
      const sharedLength = Math.min(expected?.length ?? 0, observed?.length ?? 0);
      while (
        firstDifference < sharedLength &&
        expected[firstDifference] === observed[firstDifference]
      ) {
        firstDifference += 1;
      }
      addExample(examples, {
        topic,
        firstDifference,
        expected: expected?.[firstDifference] ?? null,
        observed: observed?.[firstDifference] ?? null,
      });
    }
  }

  return {
    verified: true,
    topicsExpected: expectedByTopic.size,
    topicsObserved: observedByTopic.size,
    eventsExpected,
    eventsObserved,
    sequenceMismatches,
    examples,
  };
}

export function validateClusterCursors(database, expectedNodeIds) {
  if (
    !Number.isSafeInteger(database?.event_head) ||
    database.event_head < 0 ||
    !Array.isArray(database?.node_cursors) ||
    !Array.isArray(expectedNodeIds) ||
    expectedNodeIds.length === 0
  ) {
    throw new Error("database cursor snapshot is invalid");
  }

  const expected = new Set(expectedNodeIds);
  if (expected.size !== expectedNodeIds.length) {
    throw new Error("expected cluster node IDs are not unique");
  }

  const observed = new Set();
  const nodes = database.node_cursors.map((cursor) => {
    if (
      typeof cursor?.node_id !== "string" ||
      cursor.node_id.length === 0 ||
      observed.has(cursor.node_id) ||
      !Number.isSafeInteger(cursor.sequence) ||
      cursor.sequence < 0 ||
      cursor.sequence > database.event_head
    ) {
      throw new Error("database cursor snapshot contains an invalid node");
    }
    observed.add(cursor.node_id);
    return {
      nodeId: cursor.node_id,
      sequence: cursor.sequence,
      lag: database.event_head - cursor.sequence,
    };
  });

  const missingNodes = expectedNodeIds.filter((nodeId) => !observed.has(nodeId));
  const unexpectedNodes = nodes
    .map((node) => node.nodeId)
    .filter((nodeId) => !expected.has(nodeId));
  const maximumLag = nodes.reduce(
    (maximum, node) => Math.max(maximum, node.lag),
    0,
  );

  return {
    verified: true,
    eventHead: database.event_head,
    expectedNodes: expectedNodeIds.length,
    observedNodes: nodes.length,
    missingNodes,
    unexpectedNodes,
    laggingNodes: nodes.filter((node) => node.lag > 0).length,
    maximumLag,
    nodes,
  };
}

function checkedPair(topic, messageId, source) {
  if (!topicPattern.test(topic) || !messageIdPattern.test(messageId)) {
    throw new Error(`${source} contains invalid topic or message ID`);
  }
}

async function readExpected(sequencePath) {
  const byTopic = new Map();
  const encoded = await readFile(sequencePath, "utf8");
  for (const line of encoded.split("\n")) {
    if (!line) continue;
    const record = JSON.parse(line);
    if (
      typeof record.topic !== "string" ||
      !Array.isArray(record.messageIds) ||
      byTopic.has(record.topic)
    ) {
      throw new Error("observed sequence file has an invalid record");
    }
    for (const messageId of record.messageIds) {
      checkedPair(record.topic, messageId, "observed sequence file");
    }
    byTopic.set(record.topic, record.messageIds);
  }
  return byTopic;
}

async function readEventLog(eventLogPath) {
  const byTopic = new Map();
  const encoded = await readFile(eventLogPath, "utf8");
  for (const line of encoded.split("\n")) {
    if (!line) continue;
    const fields = line.split("\t");
    if (fields.length !== 2) {
      throw new Error("event-log export has an invalid record");
    }
    const [topic, messageId] = fields;
    checkedPair(topic, messageId, "event-log export");
    const messageIds = byTopic.get(topic) ?? [];
    messageIds.push(messageId);
    byTopic.set(topic, messageIds);
  }
  return byTopic;
}

export async function verifyReport(
  reportPath,
  sequencePath,
  eventLogPath,
  databasePath,
) {
  const report = JSON.parse(await readFile(reportPath, "utf8"));
  if (report.schemaVersion !== 1 || report.configuration === undefined) {
    throw new Error("soak report is incomplete");
  }
  const expected = await readExpected(sequencePath);
  const observed = await readEventLog(eventLogPath);
  const database = JSON.parse(await readFile(databasePath, "utf8"));
  report.durableEventLog = validateDurableSequences(expected, observed);
  report.clusterCursors = validateClusterCursors(database, expectedClusterNodes);
  report.verdict = evaluateReport(report);
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  return report;
}

async function main() {
  const [reportPath, sequencePath, eventLogPath, databasePath] =
    process.argv.slice(2);
  if (!reportPath || !sequencePath || !eventLogPath || !databasePath) {
    throw new Error(
      "usage: cluster_soak_oracle.mjs REPORT OBSERVED_SEQUENCES EVENT_LOG DATABASE",
    );
  }
  const report = await verifyReport(
    reportPath,
    sequencePath,
    eventLogPath,
    databasePath,
  );
  process.stdout.write(`${JSON.stringify(report.durableEventLog)}\n`);
  if (!report.verdict.passed) process.exitCode = 1;
}

const invokedPath = process.argv[1]
  ? pathToFileURL(path.resolve(process.argv[1])).href
  : "";
if (import.meta.url === invokedPath) {
  main().catch((error) => {
    process.stderr.write(`durable event-log verification failed: ${error.message}\n`);
    process.exitCode = 1;
  });
}
