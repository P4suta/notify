// SPDX-License-Identifier: Apache-2.0
import assert from "node:assert/strict";
import test from "node:test";

import {
  decodeWebSocketFrames,
  evaluateReport,
  loadConfiguration,
  parseSubscriptionChunk,
  percentile,
  subscriptionPath,
  validateEndpoints,
  validateTopicSequences,
} from "./cluster_soak.mjs";
import {
  validateClusterCursors,
  validateDurableSequences,
} from "./cluster_soak_oracle.mjs";

test("target defaults are the production-readiness acceptance values", () => {
  const configuration = loadConfiguration({});

  assert.equal(configuration.subscriptions, 10_000);
  assert.equal(configuration.publishRate, 500);
  assert.equal(configuration.durationSeconds, 600);
  assert.equal(configuration.topics, 1_000);
  assert.equal(configuration.commitP95BudgetMs, 200);
  assert.equal(configuration.format, "json");
  assert.deepEqual(configuration.endpoints, [
    "http://127.0.0.1:8080",
    "http://127.0.0.1:8081",
    "http://127.0.0.1:8082",
  ]);
});

test("all streaming transports are explicit validated configuration", () => {
  for (const format of ["json", "raw", "sse", "websocket"]) {
    const configuration = loadConfiguration({ NOTIFY_SOAK_FORMAT: format });
    assert.equal(configuration.format, format);
  }
  assert.throws(
    () => loadConfiguration({ NOTIFY_SOAK_FORMAT: "xml" }),
    /NOTIFY_SOAK_FORMAT/,
  );
  assert.equal(subscriptionPath("alerts", "json"), "/alerts/json?since=none");
  assert.equal(subscriptionPath("alerts", "raw"), "/alerts/raw?since=none");
  assert.equal(subscriptionPath("alerts", "sse"), "/alerts/sse?since=none");
  assert.equal(
    subscriptionPath("alerts", "websocket"),
    "/alerts/ws?since=none",
  );
});

test("JSON, SSE, and raw parsers accept split frames without losing identity", () => {
  for (const [format, chunks, expected] of [
    [
      "json",
      [
        '{"event":"open","topic":"alerts","id":"Open00000001","time":1}\n{"event":"mess',
        'age","topic":"alerts","id":"Message00001","message":"soak-0"}\n',
      ],
      [{ id: "Message00001", payload: "soak-0" }],
    ],
    [
      "sse",
      [
        'event: open\ndata: {"event":"open","topic":"alerts","id":"Open00000001","time":1}\n\nevent: message\nda',
        'ta: {"event":"message","topic":"alerts","id":"Message00001","message":"soak-0"}\n\n',
      ],
      [{ id: "Message00001", payload: "soak-0" }],
    ],
    ["raw", ["\nso", "ak-0\n"], [{ id: null, payload: "soak-0" }]],
  ]) {
    const state = {
      index: 0,
      topic: "alerts",
      buffer: "",
      opened: false,
      resolveOpen() {},
    };
    const deliveries = [];
    const errors = [];
    for (const chunk of chunks) {
      parseSubscriptionChunk(
        format,
        state,
        chunk,
        (delivery) => deliveries.push(delivery),
        (error) => errors.push(error),
      );
    }
    assert.equal(state.opened, true);
    assert.deepEqual(deliveries, expected);
    assert.deepEqual(errors, []);
  }
});

test("every streaming parser records keepalives without treating them as messages", () => {
  for (const [format, chunks] of [
    [
      "json",
      [
        '{"event":"open","topic":"alerts","id":"Open00000001","time":1}\n',
        '{"event":"keepalive","topic":"alerts","id":"Keep00000001","time":46}\n',
      ],
    ],
    [
      "sse",
      [
        'event: open\ndata: {"event":"open","topic":"alerts","id":"Open00000001","time":1}\n\n',
        'event: keepalive\ndata: {"event":"keepalive","topic":"alerts","id":"Keep00000001","time":46}\n\n',
      ],
    ],
    ["raw", ["\n", "\n"]],
  ]) {
    const state = {
      index: 0,
      topic: "alerts",
      buffer: "",
      keepalives: 0,
      opened: false,
      resolveOpen() {},
    };
    const deliveries = [];
    const errors = [];
    for (const chunk of chunks) {
      parseSubscriptionChunk(
        format,
        state,
        chunk,
        (delivery) => deliveries.push(delivery),
        (error) => errors.push(error),
      );
    }
    assert.equal(state.keepalives, 1);
    assert.deepEqual(deliveries, []);
    assert.deepEqual(errors, []);
  }
});

test("WebSocket decoder handles split unmasked text frames", () => {
  const payload = Buffer.from('{"event":"message"}', "utf8");
  const frame = Buffer.concat([Buffer.from([0x81, payload.length]), payload]);
  const state = { websocketBuffer: Buffer.alloc(0) };
  const texts = [];
  const errors = [];
  decodeWebSocketFrames(
    state,
    frame.subarray(0, 3),
    (text) => texts.push(text),
    (error) => errors.push(error),
  );
  decodeWebSocketFrames(
    state,
    frame.subarray(3),
    (text) => texts.push(text),
    (error) => errors.push(error),
  );
  assert.deepEqual(texts, ['{"event":"message"}']);
  assert.deepEqual(errors, []);
});

test("configuration rejects unsafe or internally inconsistent values", () => {
  assert.throws(
    () => loadConfiguration({ NOTIFY_SOAK_SUBSCRIPTIONS: "0" }),
    /NOTIFY_SOAK_SUBSCRIPTIONS/,
  );
  assert.throws(
    () =>
      loadConfiguration({
        NOTIFY_SOAK_SUBSCRIPTIONS: "10",
        NOTIFY_SOAK_TOPICS: "11",
      }),
    /topics cannot exceed subscriptions/,
  );
  assert.throws(
    () => loadConfiguration({ NOTIFY_SOAK_DURATION_SECONDS: "1.5" }),
    /NOTIFY_SOAK_DURATION_SECONDS/,
  );
});

test("remote endpoints are denied unless an explicit safety override is set", () => {
  assert.doesNotThrow(() =>
    validateEndpoints([
      "http://127.0.0.1:8080",
      "http://localhost:8081",
      "http://[::1]:8082",
    ]),
  );
  assert.throws(
    () => validateEndpoints(["https://notify.example"]),
    /refusing non-loopback soak endpoint/,
  );
  assert.doesNotThrow(() =>
    validateEndpoints(["https://notify.example"], { allowRemote: true }),
  );
});

test("percentile uses nearest-rank without mutating samples", () => {
  const samples = [8, 1, 3, 2, 5, 4, 7, 6, 10, 9];

  assert.equal(percentile(samples, 0.5), 5);
  assert.equal(percentile(samples, 0.95), 10);
  assert.deepEqual(samples, [8, 1, 3, 2, 5, 4, 7, 6, 10, 9]);
  assert.equal(percentile([], 0.95), null);
});

test("topic sequence validation detects loss, duplicates, and reordered delivery", () => {
  const publishedByTopic = new Map([
    ["topic-a", new Set(["Message00001", "Message00002", "Message00003"])],
  ]);
  const subscribers = [
    {
      index: 0,
      topic: "topic-a",
      messageIds: ["Message00001", "Message00002", "Message00003"],
    },
    {
      index: 1,
      topic: "topic-a",
      messageIds: ["Message00001", "Message00003", "Message00002"],
    },
    {
      index: 2,
      topic: "topic-a",
      messageIds: ["Message00001", "Message00001", "Message00003"],
    },
  ];

  const validation = validateTopicSequences(publishedByTopic, subscribers);

  assert.equal(validation.missingDeliveries, 1);
  assert.equal(validation.duplicateDeliveries, 1);
  assert.equal(validation.unexpectedDeliveries, 0);
  assert.equal(validation.orderMismatches, 2);
  assert.ok(validation.examples.length <= 100);
});

test("durable oracle compares subscriber order with event-log sequence", () => {
  const expected = new Map([
    ["topic-a", ["Message00001", "Message00002"]],
    ["topic-b", ["Message00003"]],
  ]);
  const matching = new Map([
    ["topic-a", ["Message00001", "Message00002"]],
    ["topic-b", ["Message00003"]],
  ]);
  const reordered = new Map([
    ["topic-a", ["Message00002", "Message00001"]],
    ["topic-b", ["Message00003"]],
  ]);

  assert.deepEqual(validateDurableSequences(expected, matching), {
    verified: true,
    topicsExpected: 2,
    topicsObserved: 2,
    eventsExpected: 3,
    eventsObserved: 3,
    sequenceMismatches: 0,
    examples: [],
  });
  const failed = validateDurableSequences(expected, reordered);
  assert.equal(failed.sequenceMismatches, 1);
  assert.deepEqual(failed.examples[0], {
    topic: "topic-a",
    firstDifference: 0,
    expected: "Message00001",
    observed: "Message00002",
  });
});

test("cluster cursor oracle requires every node at the durable event head", () => {
  const caughtUp = validateClusterCursors(
    {
      event_head: 42,
      node_cursors: [
        { node_id: "notify-a", sequence: 42 },
        { node_id: "notify-b", sequence: 42 },
        { node_id: "notify-c", sequence: 42 },
      ],
    },
    ["notify-a", "notify-b", "notify-c"],
  );
  assert.equal(caughtUp.maximumLag, 0);
  assert.equal(caughtUp.laggingNodes, 0);
  assert.deepEqual(caughtUp.missingNodes, []);

  const lagging = validateClusterCursors(
    {
      event_head: 42,
      node_cursors: [
        { node_id: "notify-a", sequence: 42 },
        { node_id: "notify-b", sequence: 39 },
        { node_id: "unexpected", sequence: 40 },
      ],
    },
    ["notify-a", "notify-b", "notify-c"],
  );
  assert.equal(lagging.maximumLag, 3);
  assert.equal(lagging.laggingNodes, 2);
  assert.deepEqual(lagging.missingNodes, ["notify-c"]);
  assert.deepEqual(lagging.unexpectedNodes, ["unexpected"]);

  assert.throws(
    () =>
      validateClusterCursors(
        {
          event_head: 42,
          node_cursors: [{ node_id: "notify-a", sequence: 43 }],
        },
        ["notify-a"],
      ),
    /invalid node/,
  );
});

test("acceptance verdict is fail-closed across every target invariant", () => {
  const passing = {
    configuration: {
      subscriptions: 10,
      publishRate: 5,
      durationSeconds: 2,
      commitP95BudgetMs: 200,
    },
    subscriptions: {
      ready: 10,
      disconnected: 0,
      errors: 0,
      minimumKeepalives: 0,
    },
    publishes: {
      planned: 10,
      committed: 10,
      errors: 0,
      achievedRate: 5,
      maximumSchedulingLagMs: 4,
      commitLatencyMs: { p95: 199 },
    },
    deliveries: {
      expected: 20,
      received: 20,
      missing: 0,
      duplicates: 0,
      unexpected: 0,
      orderMismatches: 0,
    },
    durableEventLog: {
      verified: true,
      sequenceMismatches: 0,
      eventsExpected: 10,
      eventsObserved: 10,
    },
    clusterCursors: {
      verified: true,
      expectedNodes: 3,
      observedNodes: 3,
      missingNodes: [],
      unexpectedNodes: [],
      laggingNodes: 0,
      maximumLag: 0,
    },
  };

  assert.equal(evaluateReport(passing).passed, true);
  const failed = structuredClone(passing);
  failed.deliveries.duplicates = 1;
  failed.publishes.commitLatencyMs.p95 = 201;
  const verdict = evaluateReport(failed);
  assert.equal(verdict.passed, false);
  assert.ok(verdict.failures.some((failure) => failure.includes("duplicates")));
  assert.ok(verdict.failures.some((failure) => failure.includes("p95")));

  const missingKeepalives = structuredClone(passing);
  missingKeepalives.configuration.durationSeconds = 600;
  missingKeepalives.configuration.publishRate = 1;
  missingKeepalives.publishes.planned = 600;
  missingKeepalives.publishes.committed = 600;
  missingKeepalives.durableEventLog.eventsExpected = 600;
  missingKeepalives.durableEventLog.eventsObserved = 600;
  assert.equal(evaluateReport(missingKeepalives).passed, false);
  assert.ok(
    evaluateReport(missingKeepalives).failures.some((failure) =>
      failure.includes("keepalives"),
    ),
  );

  const unverified = structuredClone(passing);
  delete unverified.durableEventLog;
  assert.equal(evaluateReport(unverified).passed, false);
  assert.ok(
    evaluateReport(unverified).failures.some((failure) =>
      failure.includes("not verified"),
    ),
  );

  const lagging = structuredClone(passing);
  lagging.clusterCursors.maximumLag = 1;
  lagging.clusterCursors.laggingNodes = 1;
  assert.equal(evaluateReport(lagging).passed, false);
  assert.ok(
    evaluateReport(lagging).failures.some((failure) =>
      failure.includes("cursor lag"),
    ),
  );
});
