#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
import { mkdir, writeFile } from "node:fs/promises";
import { createHash, randomBytes } from "node:crypto";
import http from "node:http";
import https from "node:https";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { performance } from "node:perf_hooks";
import {
  isMainThread,
  parentPort,
  workerData,
  Worker,
} from "node:worker_threads";

const messageIdPattern = /^[A-Za-z0-9]{12}$/;
const topicPattern = /^[-_A-Za-z0-9]{1,64}$/;
const maximumExamples = 100;
const keepaliveIntervalSeconds = 45;
const publisherWorkerMode = "publisher";

function integer(environment, name, defaultValue, minimum, maximum) {
  const raw = environment[name];
  if (raw === undefined || raw === "") return defaultValue;
  if (!/^[0-9]+$/.test(raw)) {
    throw new Error(`${name} must be an integer from ${minimum} to ${maximum}`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} to ${maximum}`);
  }
  return value;
}

export function loadConfiguration(environment = process.env) {
  const subscriptions = integer(
    environment,
    "NOTIFY_SOAK_SUBSCRIPTIONS",
    10_000,
    1,
    100_000,
  );
  const topics = integer(
    environment,
    "NOTIFY_SOAK_TOPICS",
    1_000,
    1,
    10_000,
  );
  if (topics > subscriptions) {
    throw new Error("topics cannot exceed subscriptions");
  }
  const endpoints = (
    environment.NOTIFY_SOAK_ENDPOINTS ??
    "http://127.0.0.1:8080,http://127.0.0.1:8081,http://127.0.0.1:8082"
  )
    .split(",")
    .map((endpoint) => endpoint.trim())
    .filter(Boolean);
  if (endpoints.length !== 3) {
    throw new Error("NOTIFY_SOAK_ENDPOINTS must contain exactly three URLs");
  }
  const topicPrefix =
    environment.NOTIFY_SOAK_TOPIC_PREFIX ?? `soak-${process.pid}`;
  if (!/^[-_A-Za-z0-9]{1,40}$/.test(topicPrefix)) {
    throw new Error(
      "NOTIFY_SOAK_TOPIC_PREFIX must be 1-40 ASCII letters, digits, '-' or '_'",
    );
  }
  const allowRemote = environment.NOTIFY_SOAK_ALLOW_REMOTE === "1";
  validateEndpoints(endpoints, { allowRemote });
  const format = environment.NOTIFY_SOAK_FORMAT ?? "json";
  if (!["json", "raw", "sse", "websocket"].includes(format)) {
    throw new Error(
      "NOTIFY_SOAK_FORMAT must be json, raw, sse, or websocket",
    );
  }

  return {
    subscriptions,
    topics,
    publishRate: integer(
      environment,
      "NOTIFY_SOAK_PUBLISH_RATE",
      500,
      1,
      10_000,
    ),
    durationSeconds: integer(
      environment,
      "NOTIFY_SOAK_DURATION_SECONDS",
      600,
      1,
      86_400,
    ),
    commitP95BudgetMs: integer(
      environment,
      "NOTIFY_SOAK_COMMIT_P95_MS",
      200,
      1,
      60_000,
    ),
    schedulingLagBudgetMs: integer(
      environment,
      "NOTIFY_SOAK_SCHEDULING_LAG_MS",
      1_000,
      1,
      60_000,
    ),
    settleSeconds: integer(
      environment,
      "NOTIFY_SOAK_SETTLE_SECONDS",
      60,
      1,
      600,
    ),
    connectionBatch: integer(
      environment,
      "NOTIFY_SOAK_CONNECTION_BATCH",
      200,
      1,
      2_000,
    ),
    publishConcurrency: integer(
      environment,
      "NOTIFY_SOAK_PUBLISH_CONCURRENCY",
      1_024,
      1,
      10_000,
    ),
    connectTimeoutSeconds: integer(
      environment,
      "NOTIFY_SOAK_CONNECT_TIMEOUT_SECONDS",
      180,
      1,
      1_800,
    ),
    endpoints,
    format,
    topicPrefix,
    reportPath: environment.NOTIFY_SOAK_REPORT_PATH ?? "",
    sequencePath: environment.NOTIFY_SOAK_SEQUENCE_PATH ?? "",
    allowRemote,
  };
}

export function validateEndpoints(endpoints, { allowRemote = false } = {}) {
  for (const endpoint of endpoints) {
    let parsed;
    try {
      parsed = new URL(endpoint);
    } catch {
      throw new Error(`invalid soak endpoint: ${endpoint}`);
    }
    if (!['http:', 'https:'].includes(parsed.protocol)) {
      throw new Error(`invalid soak endpoint protocol: ${parsed.protocol}`);
    }
    if (
      parsed.username ||
      parsed.password ||
      parsed.pathname !== "/" ||
      parsed.search ||
      parsed.hash
    ) {
      throw new Error(`soak endpoint must be an origin without credentials: ${endpoint}`);
    }
    const loopback = ["127.0.0.1", "localhost", "[::1]"].includes(
      parsed.hostname,
    );
    if (!loopback && !allowRemote) {
      throw new Error(`refusing non-loopback soak endpoint: ${endpoint}`);
    }
  }
}

export function percentile(samples, fraction) {
  if (samples.length === 0) return null;
  if (!(fraction > 0 && fraction <= 1)) {
    throw new Error("percentile fraction must be greater than zero and at most one");
  }
  const sorted = [...samples].sort((left, right) => left - right);
  const rank = Math.max(0, Math.ceil(fraction * sorted.length) - 1);
  return sorted[rank];
}

function addExample(examples, detail) {
  if (examples.length < maximumExamples) examples.push(detail);
}

function arraysEqual(left, right) {
  return (
    left.length === right.length &&
    left.every((value, index) => value === right[index])
  );
}

export function validateTopicSequences(publishedByTopic, subscribers) {
  const subscribersByTopic = new Map();
  for (const subscriber of subscribers) {
    const grouped = subscribersByTopic.get(subscriber.topic) ?? [];
    grouped.push(subscriber);
    subscribersByTopic.set(subscriber.topic, grouped);
  }

  let missingDeliveries = 0;
  let duplicateDeliveries = 0;
  let unexpectedDeliveries = 0;
  let orderMismatches = 0;
  const examples = [];

  for (const [topic, published] of publishedByTopic) {
    const topicSubscribers = subscribersByTopic.get(topic) ?? [];
    const canonical = topicSubscribers[0]?.messageIds ?? [];
    for (const subscriber of topicSubscribers) {
      const counts = new Map();
      for (const id of subscriber.messageIds) {
        counts.set(id, (counts.get(id) ?? 0) + 1);
      }
      for (const [id, count] of counts) {
        if (count > 1) {
          duplicateDeliveries += count - 1;
          addExample(examples, {
            kind: "duplicate",
            subscriber: subscriber.index,
            topic,
            messageId: id,
            count,
          });
        }
        if (!published.has(id)) {
          unexpectedDeliveries += count;
          addExample(examples, {
            kind: "unexpected",
            subscriber: subscriber.index,
            topic,
            messageId: id,
          });
        }
      }
      for (const id of published) {
        if (!counts.has(id)) {
          missingDeliveries += 1;
          addExample(examples, {
            kind: "missing",
            subscriber: subscriber.index,
            topic,
            messageId: id,
          });
        }
      }
      if (!arraysEqual(subscriber.messageIds, canonical)) {
        orderMismatches += 1;
        addExample(examples, {
          kind: "order",
          subscriber: subscriber.index,
          topic,
        });
      }
    }
  }

  return {
    missingDeliveries,
    duplicateDeliveries,
    unexpectedDeliveries,
    orderMismatches,
    examples,
  };
}

export function evaluateReport(report) {
  const failures = [];
  const expect = (condition, failure) => {
    if (!condition) failures.push(failure);
  };
  const configuration = report.configuration;
  const expectedPublishes =
    configuration.publishRate * configuration.durationSeconds;
  expect(
    report.subscriptions.ready === configuration.subscriptions,
    `ready subscriptions ${report.subscriptions.ready}/${configuration.subscriptions}`,
  );
  expect(
    report.subscriptions.errors === 0,
    `subscription errors ${report.subscriptions.errors}`,
  );
  expect(
    report.subscriptions.disconnected === 0,
    `stable-connection disconnects ${report.subscriptions.disconnected}`,
  );
  const requiredKeepalives =
    configuration.durationSeconds < keepaliveIntervalSeconds * 2
      ? 0
      : Math.max(
          1,
          Math.floor(
            configuration.durationSeconds / keepaliveIntervalSeconds,
          ) - 1,
        );
  expect(
    requiredKeepalives === 0 ||
      report.subscriptions.minimumKeepalives >= requiredKeepalives,
    `minimum keepalives ${report.subscriptions.minimumKeepalives ?? "unknown"}/${requiredKeepalives}`,
  );
  expect(
    report.publishes.planned === expectedPublishes,
    `planned publishes ${report.publishes.planned}/${expectedPublishes}`,
  );
  expect(
    report.publishes.committed === expectedPublishes,
    `committed publishes ${report.publishes.committed}/${expectedPublishes}`,
  );
  expect(report.publishes.errors === 0, `publish errors ${report.publishes.errors}`);
  expect(
    report.publishes.achievedRate >= configuration.publishRate * 0.99,
    `achieved publish rate ${report.publishes.achievedRate.toFixed(2)}/${configuration.publishRate}`,
  );
  expect(
    report.publishes.maximumSchedulingLagMs <=
      (configuration.schedulingLagBudgetMs ?? 1_000),
    `maximum scheduling lag ${report.publishes.maximumSchedulingLagMs.toFixed(2)} ms`,
  );
  expect(
    report.publishes.commitLatencyMs.p95 !== null &&
      report.publishes.commitLatencyMs.p95 <= configuration.commitP95BudgetMs,
    `publish commit p95 ${report.publishes.commitLatencyMs.p95} ms exceeds ${configuration.commitP95BudgetMs} ms`,
  );
  expect(
    report.deliveries.received === report.deliveries.expected,
    `received deliveries ${report.deliveries.received}/${report.deliveries.expected}`,
  );
  expect(report.deliveries.missing === 0, `missing deliveries ${report.deliveries.missing}`);
  expect(
    report.deliveries.duplicates === 0,
    `duplicates ${report.deliveries.duplicates}`,
  );
  expect(
    report.deliveries.unexpected === 0,
    `unexpected deliveries ${report.deliveries.unexpected}`,
  );
  expect(
    report.deliveries.orderMismatches === 0,
    `topic-order mismatches ${report.deliveries.orderMismatches}`,
  );
  const durable = report.durableEventLog;
  expect(
    durable?.verified === true,
    "durable event-log order was not verified",
  );
  expect(
    durable?.sequenceMismatches === 0,
    `durable event-log sequence mismatches ${durable?.sequenceMismatches ?? "unknown"}`,
  );
  expect(
    durable?.eventsExpected === expectedPublishes,
    `durable event-log expected events ${durable?.eventsExpected ?? "unknown"}/${expectedPublishes}`,
  );
  expect(
    durable?.eventsObserved === expectedPublishes,
    `durable event-log observed events ${durable?.eventsObserved ?? "unknown"}/${expectedPublishes}`,
  );
  const cursors = report.clusterCursors;
  expect(cursors?.verified === true, "cluster cursor state was not verified");
  expect(
    cursors?.observedNodes === cursors?.expectedNodes,
    `cluster cursors ${cursors?.observedNodes ?? "unknown"}/${cursors?.expectedNodes ?? "unknown"}`,
  );
  expect(
    cursors?.missingNodes?.length === 0,
    `missing cluster cursors ${(cursors?.missingNodes ?? []).join(",") || "unknown"}`,
  );
  expect(
    cursors?.unexpectedNodes?.length === 0,
    `unexpected cluster cursors ${(cursors?.unexpectedNodes ?? []).join(",") || "unknown"}`,
  );
  expect(
    cursors?.laggingNodes === 0 && cursors?.maximumLag === 0,
    `cluster cursor lag ${cursors?.maximumLag ?? "unknown"} events across ${cursors?.laggingNodes ?? "unknown"} nodes`,
  );
  return { passed: failures.length === 0, failures };
}

export function evaluatePreliminaryReport(report) {
  return evaluateReport({
    ...report,
    durableEventLog: {
      verified: true,
      sequenceMismatches: 0,
      eventsExpected: report.publishes.planned,
      eventsObserved: report.publishes.committed,
    },
    clusterCursors: {
      verified: true,
      expectedNodes: report.configuration.endpoints.length,
      observedNodes: report.configuration.endpoints.length,
      missingNodes: [],
      unexpectedNodes: [],
      laggingNodes: 0,
      maximumLag: 0,
    },
  });
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function transport(url) {
  return url.protocol === "https:" ? https : http;
}

function createAgent(endpoint, maximumSockets) {
  const parsed = new URL(endpoint);
  const Agent = parsed.protocol === "https:" ? https.Agent : http.Agent;
  return new Agent({
    keepAlive: true,
    maxSockets: maximumSockets,
    maxFreeSockets: 512,
    scheduling: "fifo",
  });
}

function messagePath(topic) {
  return `/${encodeURIComponent(topic)}`;
}

export function publishEndpointIndex(index, endpointCount) {
  if (!Number.isSafeInteger(index) || index < 0) {
    throw new Error("publish index must be a non-negative safe integer");
  }
  if (!Number.isSafeInteger(endpointCount) || endpointCount < 1) {
    throw new Error("endpoint count must be a positive safe integer");
  }
  return index % endpointCount;
}

export function subscriptionPath(topic, format) {
  const suffix = format === "websocket" ? "ws" : format;
  return `${messagePath(topic)}/${suffix}?since=none`;
}

function acceptEvent(state, event, onDelivery, onError) {
  if (event.event === "open") {
    state.opened = true;
    state.resolveOpen();
    return;
  }
  if (event.event === "keepalive") {
    state.keepalives = (state.keepalives ?? 0) + 1;
    return;
  }
  if (event.event !== "message") {
    onError(`subscriber ${state.index} received unexpected event`);
    return;
  }
  if (
    !messageIdPattern.test(event.id) ||
    event.topic !== state.topic ||
    typeof event.message !== "string"
  ) {
    onError(`subscriber ${state.index} received malformed message metadata`);
    return;
  }
  onDelivery({ id: event.id, payload: event.message });
}

function parseJsonEvent(state, encoded, onDelivery, onError) {
  let event;
  try {
    event = JSON.parse(encoded);
  } catch (error) {
    onError(`subscriber ${state.index} received invalid JSON: ${error.message}`);
    return;
  }
  acceptEvent(state, event, onDelivery, onError);
}

function parseNdjson(state, chunk, onDelivery, onError) {
  state.buffer += chunk;
  for (;;) {
    const newline = state.buffer.indexOf("\n");
    if (newline < 0) break;
    const line = state.buffer.slice(0, newline).trim();
    state.buffer = state.buffer.slice(newline + 1);
    if (!line) continue;
    parseJsonEvent(state, line, onDelivery, onError);
  }
}

function parseSse(state, chunk, onDelivery, onError) {
  state.buffer += chunk.replaceAll("\r\n", "\n");
  for (;;) {
    const boundary = state.buffer.indexOf("\n\n");
    if (boundary < 0) break;
    const frame = state.buffer.slice(0, boundary);
    state.buffer = state.buffer.slice(boundary + 2);
    const data = frame
      .split("\n")
      .filter((line) => line.startsWith("data:"))
      .map((line) => line.slice(5).replace(/^ /, ""))
      .join("\n");
    if (data) parseJsonEvent(state, data, onDelivery, onError);
  }
}

function parseRaw(state, chunk, onDelivery, onError) {
  state.buffer += chunk;
  for (;;) {
    const newline = state.buffer.indexOf("\n");
    if (newline < 0) break;
    const line = state.buffer.slice(0, newline).replace(/\r$/, "");
    state.buffer = state.buffer.slice(newline + 1);
    if (!state.opened) {
      if (line !== "") {
        onError(`subscriber ${state.index} did not receive the raw open event`);
      }
      state.opened = true;
      state.resolveOpen();
      continue;
    }
    if (line === "") {
      state.keepalives = (state.keepalives ?? 0) + 1;
      continue;
    }
    if (!/^soak-[0-9]+$/.test(line)) {
      onError(`subscriber ${state.index} received malformed raw payload`);
      continue;
    }
    onDelivery({ id: null, payload: line });
  }
}

export function parseSubscriptionChunk(
  format,
  state,
  chunk,
  onDelivery,
  onError,
) {
  if (format === "json") return parseNdjson(state, chunk, onDelivery, onError);
  if (format === "sse") return parseSse(state, chunk, onDelivery, onError);
  if (format === "raw") return parseRaw(state, chunk, onDelivery, onError);
  throw new Error(`unsupported HTTP subscription format: ${format}`);
}

const emptyWebSocketBuffer = Buffer.alloc(0);
const websocketTextDecoder = new TextDecoder("utf-8", { fatal: true });

export function decodeWebSocketFrames(
  state,
  chunk,
  onText,
  onError,
  onControl = () => {},
) {
  const incoming = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
  const pending = state.websocketBuffer ?? emptyWebSocketBuffer;
  const buffer =
    pending.length === 0 ? incoming : Buffer.concat([pending, incoming]);
  let cursor = 0;
  while (buffer.length - cursor >= 2) {
    const first = buffer[cursor];
    const second = buffer[cursor + 1];
    const final = (first & 0x80) !== 0;
    const opcode = first & 0x0f;
    const masked = (second & 0x80) !== 0;
    let length = second & 0x7f;
    let payloadOffset = cursor + 2;
    if ((first & 0x70) !== 0 || masked || !final) {
      onError(`subscriber ${state.index ?? "?"} received an invalid WebSocket frame`);
      state.websocketBuffer = emptyWebSocketBuffer;
      return;
    }
    if (length === 126) {
      if (buffer.length - cursor < 4) break;
      length = buffer.readUInt16BE(cursor + 2);
      payloadOffset = cursor + 4;
    } else if (length === 127) {
      if (buffer.length - cursor < 10) break;
      const wideLength = buffer.readBigUInt64BE(cursor + 2);
      if (wideLength > BigInt(Number.MAX_SAFE_INTEGER)) {
        onError(`subscriber ${state.index ?? "?"} received an oversized WebSocket frame`);
        state.websocketBuffer = emptyWebSocketBuffer;
        return;
      }
      length = Number(wideLength);
      payloadOffset = cursor + 10;
    }
    const frameEnd = payloadOffset + length;
    if (buffer.length < frameEnd) break;
    const payload = buffer.subarray(payloadOffset, frameEnd);
    cursor = frameEnd;
    if (opcode === 0x1) {
      try {
        onText(websocketTextDecoder.decode(payload));
      } catch {
        onError(`subscriber ${state.index ?? "?"} received invalid WebSocket UTF-8`);
      }
    } else if ([0x8, 0x9, 0xa].includes(opcode)) {
      onControl(opcode, payload);
    } else {
      onError(`subscriber ${state.index ?? "?"} received unsupported WebSocket opcode`);
    }
  }
  state.websocketBuffer =
    cursor === buffer.length
      ? emptyWebSocketBuffer
      : Buffer.from(buffer.subarray(cursor));
}

function maskedClientFrame(opcode, payload = Buffer.alloc(0)) {
  const body = Buffer.from(payload);
  if (body.length > 125) throw new Error("WebSocket control payload is too large");
  const mask = randomBytes(4);
  const frame = Buffer.alloc(6 + body.length);
  frame[0] = 0x80 | opcode;
  frame[1] = 0x80 | body.length;
  mask.copy(frame, 2);
  for (let index = 0; index < body.length; index += 1) {
    frame[6 + index] = body[index] ^ mask[index % 4];
  }
  return frame;
}

function connectHttpSubscriber(
  state,
  endpoint,
  agent,
  timeoutMilliseconds,
  format,
  onDelivery,
  onError,
) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finishOpen = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve();
    };
    const failOpen = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    };
    state.resolveOpen = finishOpen;
    const url = new URL(subscriptionPath(state.topic, format), endpoint);
    const request = transport(url).request(url, {
      agent,
      method: "GET",
      headers: {
        accept:
          format === "json"
            ? "application/x-ndjson"
            : format === "sse"
              ? "text/event-stream"
              : "text/plain",
      },
    });
    state.request = request;
    const timer = setTimeout(() => {
      request.destroy();
      failOpen(new Error(`subscriber ${state.index} open timed out`));
    }, timeoutMilliseconds);

    request.on("response", (response) => {
      state.response = response;
      if (response.statusCode !== 200) {
        response.resume();
        failOpen(
          new Error(
            `subscriber ${state.index} returned HTTP ${response.statusCode}`,
          ),
        );
        return;
      }
      response.setEncoding("utf8");
      response.on("data", (chunk) =>
        parseSubscriptionChunk(format, state, chunk, onDelivery, onError),
      );
      const disconnected = (reason) => {
        if (!state.closing && !state.disconnected) {
          state.disconnected = true;
          onError(`subscriber ${state.index} disconnected: ${reason}`);
        }
        if (!state.opened) failOpen(new Error(`subscriber ${state.index} disconnected`));
      };
      response.on("aborted", () => disconnected("aborted"));
      response.on("error", (error) => disconnected(error.message));
      response.on("end", () => disconnected("end of stream"));
    });
    request.on("error", (error) => {
      if (!state.opened) failOpen(error);
      else if (!state.closing && !state.disconnected) {
        state.disconnected = true;
        onError(`subscriber ${state.index} request failed: ${error.message}`);
      }
    });
    request.end();
  });
}

function connectWebSocketSubscriber(
  state,
  endpoint,
  agent,
  timeoutMilliseconds,
  onDelivery,
  onError,
) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finishOpen = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve();
    };
    const failOpen = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      state.socket?.destroy();
      reject(error);
    };
    state.resolveOpen = finishOpen;
    const url = new URL(subscriptionPath(state.topic, "websocket"), endpoint);
    const key = randomBytes(16).toString("base64");
    const expectedAccept = createHash("sha1")
      .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest("base64");
    const request = transport(url).request(url, {
      agent,
      method: "GET",
      headers: {
        connection: "Upgrade",
        upgrade: "websocket",
        "sec-websocket-key": key,
        "sec-websocket-version": "13",
      },
    });
    state.request = request;
    const timer = setTimeout(() => {
      request.destroy();
      state.socket?.destroy();
      failOpen(new Error(`subscriber ${state.index} open timed out`));
    }, timeoutMilliseconds);

    request.on("upgrade", (response, socket, head) => {
      if (
        response.statusCode !== 101 ||
        response.headers["sec-websocket-accept"] !== expectedAccept
      ) {
        socket.destroy();
        failOpen(
          new Error(`subscriber ${state.index} WebSocket handshake was invalid`),
        );
        return;
      }
      state.socket = socket;
      const disconnected = (reason) => {
        if (!state.closing && !state.disconnected) {
          state.disconnected = true;
          onError(`subscriber ${state.index} disconnected: ${reason}`);
        }
        if (!state.opened) {
          failOpen(new Error(`subscriber ${state.index} disconnected`));
        }
      };
      const consume = (chunk) =>
        decodeWebSocketFrames(
          state,
          chunk,
          (text) => parseJsonEvent(state, text, onDelivery, onError),
          onError,
          (opcode, payload) => {
            if (opcode === 0x9 && !socket.destroyed) {
              socket.write(maskedClientFrame(0xa, payload));
            } else if (opcode === 0x8) {
              disconnected("close frame");
              socket.end();
            }
          },
        );
      socket.on("data", consume);
      socket.on("error", (error) => disconnected(error.message));
      socket.on("end", () => disconnected("end of stream"));
      socket.on("close", () => disconnected("closed"));
      if (head.length > 0) consume(head);
    });
    request.on("response", (response) => {
      response.resume();
      failOpen(
        new Error(
          `subscriber ${state.index} returned HTTP ${response.statusCode}`,
        ),
      );
    });
    request.on("error", (error) => {
      if (!state.opened) failOpen(error);
      else if (!state.closing && !state.disconnected) {
        state.disconnected = true;
        onError(`subscriber ${state.index} request failed: ${error.message}`);
      }
    });
    request.end();
  });
}

function connectSubscriber(
  state,
  endpoint,
  agent,
  timeoutMilliseconds,
  format,
  onDelivery,
  onError,
) {
  if (format === "websocket") {
    return connectWebSocketSubscriber(
      state,
      endpoint,
      agent,
      timeoutMilliseconds,
      onDelivery,
      onError,
    );
  }
  return connectHttpSubscriber(
    state,
    endpoint,
    agent,
    timeoutMilliseconds,
    format,
    onDelivery,
    onError,
  );
}

async function openSubscribers(configuration, topics, agents, errors) {
  const subscribers = Array.from(
    { length: configuration.subscriptions },
    (_, index) => ({
      index,
      topic: topics[index % topics.length],
      endpointIndex:
        Math.floor(index / topics.length) % configuration.endpoints.length,
      buffer: "",
      websocketBuffer: Buffer.alloc(0),
      messageIds: [],
      rawPayloads: [],
      keepalives: 0,
      opened: false,
      disconnected: false,
      closing: false,
      request: null,
      response: null,
      socket: null,
      resolveOpen: () => {},
    }),
  );
  let received = 0;
  const onError = (detail) => addExample(errors, detail);
  const timeoutMilliseconds = configuration.connectTimeoutSeconds * 1_000;

  for (
    let offset = 0;
    offset < subscribers.length;
    offset += configuration.connectionBatch
  ) {
    const batch = subscribers.slice(
      offset,
      offset + configuration.connectionBatch,
    );
    await Promise.all(
      batch.map((subscriber) =>
        connectSubscriber(
          subscriber,
          configuration.endpoints[subscriber.endpointIndex],
          agents[subscriber.endpointIndex],
          timeoutMilliseconds,
          configuration.format,
          (delivery) => {
            if (delivery.id === null) {
              subscriber.rawPayloads.push(delivery.payload);
            } else {
              subscriber.messageIds.push(delivery.id);
            }
            received += 1;
          },
          onError,
        ),
      ),
    );
    if (
      subscribers.length >= 1_000 &&
      (offset + batch.length) % 1_000 === 0
    ) {
      process.stderr.write(
        `ready subscriptions: ${offset + batch.length}/${subscribers.length}\n`,
      );
    }
  }
  return { subscribers, received: () => received };
}

function publishOne(index, topic, endpoint, agent) {
  const url = new URL(messagePath(topic), endpoint);
  const payload = `soak-${index}`;
  const startedAt = performance.now();
  return new Promise((resolve, reject) => {
    const request = transport(url).request(url, {
      agent,
      method: "POST",
      headers: {
        "content-type": "text/plain; charset=utf-8",
        "content-length": Buffer.byteLength(payload),
      },
    });
    request.on("response", (response) => {
      response.setEncoding("utf8");
      let body = "";
      response.on("data", (chunk) => {
        body += chunk;
        if (body.length > 65_536) request.destroy();
      });
      response.on("error", reject);
      response.on("end", () => {
        const latencyMs = performance.now() - startedAt;
        if (response.statusCode !== 200) {
          reject(new Error(`publish ${index} returned HTTP ${response.statusCode}`));
          return;
        }
        let event;
        try {
          event = JSON.parse(body);
        } catch (error) {
          reject(new Error(`publish ${index} returned invalid JSON: ${error.message}`));
          return;
        }
        if (
          event.event !== "message" ||
          event.topic !== topic ||
          event.message !== payload ||
          !messageIdPattern.test(event.id)
        ) {
          reject(new Error(`publish ${index} returned malformed message metadata`));
          return;
        }
        resolve({
          id: event.id,
          topic,
          payload,
          latencyMs,
          completedAt: performance.now(),
        });
      });
    });
    request.on("error", reject);
    request.end(payload);
  });
}

async function publishAtRate(configuration, topics, agents, errors) {
  const planned = configuration.publishRate * configuration.durationSeconds;
  const intervalMilliseconds = 1_000 / configuration.publishRate;
  const latencies = [];
  const publishedByTopic = new Map(topics.map((topic) => [topic, new Set()]));
  const publishedByPayload = new Map();
  const allIds = new Set();
  const inFlight = new Set();
  let next = 0;
  let committed = 0;
  let publishErrors = 0;
  let maximumSchedulingLagMs = 0;
  let lastCompletedAt = 0;
  const startedAt = performance.now();

  const launch = (index) => {
    const intendedAt = startedAt + index * intervalMilliseconds;
    maximumSchedulingLagMs = Math.max(
      maximumSchedulingLagMs,
      performance.now() - intendedAt,
    );
    const topic = topics[index % topics.length];
    const endpointIndex = publishEndpointIndex(
      index,
      configuration.endpoints.length,
    );
    const task = publishOne(
      index,
      topic,
      configuration.endpoints[endpointIndex],
      agents[endpointIndex],
    )
      .then((published) => {
        if (allIds.has(published.id)) {
          throw new Error(`publish generated duplicate message ID ${published.id}`);
        }
        allIds.add(published.id);
        publishedByTopic.get(topic).add(published.id);
        publishedByPayload.set(published.payload, published);
        latencies.push(published.latencyMs);
        committed += 1;
        lastCompletedAt = Math.max(lastCompletedAt, published.completedAt);
      })
      .catch((error) => {
        publishErrors += 1;
        addExample(errors, error.message);
      })
      .finally(() => inFlight.delete(task));
    inFlight.add(task);
  };

  while (next < planned) {
    const elapsed = performance.now() - startedAt;
    const due = Math.min(
      planned,
      Math.floor(elapsed / intervalMilliseconds) + 1,
    );
    while (
      next < due &&
      next < planned &&
      inFlight.size < configuration.publishConcurrency
    ) {
      launch(next);
      next += 1;
    }
    if (inFlight.size >= configuration.publishConcurrency) {
      await Promise.race(inFlight);
    } else if (next < planned) {
      const nextAt = startedAt + next * intervalMilliseconds;
      await delay(Math.max(0, Math.min(10, nextAt - performance.now())));
    }
  }
  await Promise.all(inFlight);
  const completedDurationSeconds =
    (Math.max(lastCompletedAt, performance.now()) - startedAt) / 1_000;
  return {
    planned,
    committed,
    errors: publishErrors,
    achievedRate: committed / completedDurationSeconds,
    maximumSchedulingLagMs,
    completedDurationSeconds,
    latencies,
    publishedByTopic,
    publishedByPayload,
  };
}

function publishInWorker(configuration, topics) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL(import.meta.url), {
      workerData: { mode: publisherWorkerMode, configuration, topics },
    });
    let settled = false;
    worker.once("message", (message) => {
      settled = true;
      if (message?.ok) resolve(message);
      else reject(new Error(message?.error ?? "publisher worker failed"));
    });
    worker.once("error", (error) => {
      if (!settled) reject(error);
    });
    worker.once("exit", (code) => {
      if (!settled) {
        reject(
          new Error(
            code === 0
              ? "publisher worker exited without a result"
              : `publisher worker exited with status ${code}`,
          ),
        );
      }
    });
  });
}

async function runPublisherWorker() {
  const { configuration, topics } = workerData;
  const errors = [];
  const agents = configuration.endpoints.map((endpoint) =>
    createAgent(endpoint, configuration.publishConcurrency),
  );
  try {
    const published = await publishAtRate(
      configuration,
      topics,
      agents,
      errors,
    );
    parentPort.postMessage({ ok: true, published, errors });
  } catch (error) {
    parentPort.postMessage({
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    });
  } finally {
    for (const agent of agents) agent.destroy();
  }
}

function latencySummary(samples) {
  if (samples.length === 0) {
    return { minimum: null, p50: null, p95: null, p99: null, maximum: null, mean: null };
  }
  let total = 0;
  let minimum = Number.POSITIVE_INFINITY;
  let maximum = 0;
  for (const sample of samples) {
    total += sample;
    minimum = Math.min(minimum, sample);
    maximum = Math.max(maximum, sample);
  }
  return {
    minimum,
    p50: percentile(samples, 0.5),
    p95: percentile(samples, 0.95),
    p99: percentile(samples, 0.99),
    maximum,
    mean: total / samples.length,
  };
}

function expectedDeliveries(publishedByTopic, subscribers) {
  const subscribersPerTopic = new Map();
  for (const subscriber of subscribers) {
    subscribersPerTopic.set(
      subscriber.topic,
      (subscribersPerTopic.get(subscriber.topic) ?? 0) + 1,
    );
  }
  let expected = 0;
  for (const [topic, published] of publishedByTopic) {
    expected += published.size * (subscribersPerTopic.get(topic) ?? 0);
  }
  return expected;
}

async function waitForDeliveries(received, expected, settleSeconds) {
  const deadline = performance.now() + settleSeconds * 1_000;
  while (received() < expected && performance.now() < deadline) {
    await delay(100);
  }
  if (received() >= expected) await delay(1_000);
}

function closeSubscribers(subscribers, agents) {
  for (const subscriber of subscribers) {
    subscriber.closing = true;
    subscriber.response?.destroy();
    subscriber.request?.destroy();
    subscriber.socket?.destroy();
  }
  for (const agent of agents) agent.destroy();
}

function resolveRawDeliveries(subscribers, publishedByPayload, errors) {
  for (const subscriber of subscribers) {
    if (subscriber.rawPayloads.length === 0) continue;
    subscriber.messageIds = subscriber.rawPayloads.map((payload) => {
      const published = publishedByPayload.get(payload);
      if (published?.topic === subscriber.topic) return published.id;
      addExample(
        errors,
        `subscriber ${subscriber.index} received unknown raw payload ${payload}`,
      );
      return payload;
    });
  }
}

function rounded(value) {
  return value === null ? null : Math.round(value * 100) / 100;
}

function roundedLatency(summary) {
  return Object.fromEntries(
    Object.entries(summary).map(([name, value]) => [name, rounded(value)]),
  );
}

export async function runSoak(configuration) {
  const startedAt = new Date();
  const errors = [];
  const maximumSockets =
    Math.ceil(configuration.subscriptions / configuration.endpoints.length) +
    configuration.publishConcurrency;
  const agents = configuration.endpoints.map((endpoint) =>
    createAgent(endpoint, maximumSockets),
  );
  const topics = Array.from({ length: configuration.topics }, (_, index) => {
    const topic = `${configuration.topicPrefix}-${index.toString().padStart(4, "0")}`;
    if (!topicPattern.test(topic)) throw new Error(`generated invalid topic: ${topic}`);
    return topic;
  });
  let subscribers = [];
  try {
    const opened = await openSubscribers(configuration, topics, agents, errors);
    subscribers = opened.subscribers;
    const workerResult = await publishInWorker(configuration, topics);
    errors.push(...workerResult.errors);
    const published = workerResult.published;
    const expected = expectedDeliveries(published.publishedByTopic, subscribers);
    await waitForDeliveries(opened.received, expected, configuration.settleSeconds);
    if (configuration.format === "raw") {
      resolveRawDeliveries(subscribers, published.publishedByPayload, errors);
    }
    const validation = validateTopicSequences(
      published.publishedByTopic,
      subscribers,
    );
    const report = {
      schemaVersion: 1,
      startedAt: startedAt.toISOString(),
      finishedAt: new Date().toISOString(),
      environment: {
        node: process.version,
        platform: os.platform(),
        release: os.release(),
        architecture: os.arch(),
        logicalCpus: os.availableParallelism(),
        totalMemoryBytes: os.totalmem(),
        publisherExecution: "worker_thread",
      },
      configuration: {
        subscriptions: configuration.subscriptions,
        topics: configuration.topics,
        publishRate: configuration.publishRate,
        durationSeconds: configuration.durationSeconds,
        commitP95BudgetMs: configuration.commitP95BudgetMs,
        schedulingLagBudgetMs: configuration.schedulingLagBudgetMs,
        settleSeconds: configuration.settleSeconds,
        format: configuration.format,
        endpoints: configuration.endpoints,
      },
      subscriptions: {
        ready: subscribers.filter((subscriber) => subscriber.opened).length,
        disconnected: subscribers.filter((subscriber) => subscriber.disconnected)
          .length,
        errors: errors.filter((error) => error.startsWith("subscriber ")).length,
        keepalives: subscribers.reduce(
          (total, subscriber) => total + subscriber.keepalives,
          0,
        ),
        minimumKeepalives: subscribers.reduce(
          (minimum, subscriber) => Math.min(minimum, subscriber.keepalives),
          subscribers[0]?.keepalives ?? 0,
        ),
        perNode: configuration.endpoints.map((endpoint, endpointIndex) => ({
          endpoint,
          ready: subscribers.filter(
            (subscriber) =>
              subscriber.endpointIndex === endpointIndex && subscriber.opened,
          ).length,
        })),
      },
      publishes: {
        planned: published.planned,
        committed: published.committed,
        errors: published.errors,
        achievedRate: rounded(published.achievedRate),
        maximumSchedulingLagMs: rounded(published.maximumSchedulingLagMs),
        completedDurationSeconds: rounded(published.completedDurationSeconds),
        commitLatencyMs: roundedLatency(latencySummary(published.latencies)),
      },
      deliveries: {
        expected,
        received: opened.received(),
        missing: validation.missingDeliveries,
        duplicates: validation.duplicateDeliveries,
        unexpected: validation.unexpectedDeliveries,
        orderMismatches: validation.orderMismatches,
      },
      examples: [...errors, ...validation.examples].slice(0, maximumExamples),
    };
    report.preliminaryVerdict = evaluatePreliminaryReport(report);
    await persistObservedSequences(
      subscribers,
      topics,
      configuration.sequencePath,
    );
    return report;
  } finally {
    closeSubscribers(subscribers, agents);
  }
}

async function persistObservedSequences(subscribers, topics, sequencePath) {
  if (!sequencePath) return;
  const firstByTopic = new Map();
  for (const subscriber of subscribers) {
    if (!firstByTopic.has(subscriber.topic)) {
      firstByTopic.set(subscriber.topic, subscriber.messageIds);
    }
  }
  const encoded = topics
    .map((topic) =>
      JSON.stringify({ topic, messageIds: firstByTopic.get(topic) ?? [] }),
    )
    .join("\n");
  await mkdir(path.dirname(path.resolve(sequencePath)), { recursive: true });
  await writeFile(sequencePath, `${encoded}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
}

async function persistReport(report, reportPath) {
  const encoded = `${JSON.stringify(report, null, 2)}\n`;
  process.stdout.write(encoded);
  if (reportPath) {
    await mkdir(path.dirname(path.resolve(reportPath)), { recursive: true });
    await writeFile(reportPath, encoded, { encoding: "utf8", mode: 0o600 });
  }
}

async function main() {
  const configuration = loadConfiguration();
  const report = await runSoak(configuration);
  await persistReport(report, configuration.reportPath);
  if (!report.preliminaryVerdict.passed) process.exitCode = 1;
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (!isMainThread && workerData?.mode === publisherWorkerMode) {
  await runPublisherWorker();
} else if (import.meta.url === invokedPath) {
  main().catch(async (error) => {
    const failure = {
      schemaVersion: 1,
      finishedAt: new Date().toISOString(),
      verdict: { passed: false, failures: [error.message] },
    };
    try {
      await persistReport(failure, process.env.NOTIFY_SOAK_REPORT_PATH ?? "");
    } finally {
      process.exitCode = 1;
    }
  });
}
