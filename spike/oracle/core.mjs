// The JS core against the notes server over Connect JSON (and grpc-gateway's
// NDJSON on the implicit route): node spike/oracle/core.mjs http://127.0.0.1:18080
import { test } from "node:test";
import assert from "node:assert/strict";
import { createStreams } from "../../runtime/stream.js";

const base = process.env.NOTES_URL ?? "http://127.0.0.1:18080";
const connectHeaders = [["Content-Type", "application/connect+json"], ["Connect-Protocol-Version", "1"]];

function run(open, { cancelAfter } = {}) {
  return new Promise((resolve) => {
    const events = [];
    const streams = createStreams((e) => {
      events.push(e);
      if (e.kind === "message" && cancelAfter && events.filter((x) => x.kind === "message").length === cancelAfter) {
        streams.cancel("w");
        setTimeout(() => resolve(events), 300);
      }
      if (e.kind === "end" || e.kind === "error") resolve(events);
    });
    streams.open("w", open);
  });
}

const watch = (req, extra = {}) => ({
  url: `${base}/notes.v1.NotesService/WatchNotes`,
  headers: connectHeaders,
  body: JSON.stringify(req),
  framing: "connect",
  ...extra,
});

test("connect: N messages then a clean end", async () => {
  const events = await run(watch({ count: 3, intervalMs: 10, after: 4 }));
  assert.equal(events[0].kind, "headers");
  assert.equal(events[0].status, 200);
  assert.equal(events[0].headers["content-type"], "application/connect+json");
  const indexes = events.filter((e) => e.kind === "message").map((e) => JSON.parse(e.json).index);
  assert.deepEqual(indexes, ["5", "6", "7"]);
  assert.deepEqual(events.at(-1), { id: "w", kind: "end", status: 200, error: null, metadata: {} });
});

test("connect: the end-stream error with its detail", async () => {
  const events = await run(watch({ count: 2, intervalMs: 10, fail: true }));
  const end = events.at(-1);
  assert.equal(end.kind, "end");
  assert.equal(end.status, 200);
  assert.equal(end.error.code, "failed_precondition");
  assert.equal(end.error.details[0].type, "google.rpc.ErrorInfo");
  assert.equal(end.error.details[0].debug.reason, "WATCH_ENDED");
  assert.equal(end.error.details[0].debug.metadata.index, "2");
});

test("connect: a bad request is an end-stream error inside a 200", async () => {
  const events = await run(watch({ count: "x" }));
  assert.equal(events[0].status, 200);
  assert.equal(events.at(-1).error.code, "invalid_argument");
});

test("connect: cancel mid-stream stops events", async () => {
  const events = await run(watch({ count: 10, intervalMs: 50 }), { cancelAfter: 2 });
  assert.equal(events.filter((e) => e.kind === "message").length, 2);
  assert.ok(!events.some((e) => e.kind === "end" || e.kind === "error"));
});

test("connect: the server's deadline from Connect-Timeout-Ms", async () => {
  const events = await run(watch({ count: 10, intervalMs: 50 }, { headers: [...connectHeaders, ["Connect-Timeout-Ms", "120"]] }));
  assert.equal(events.at(-1).kind, "end");
  assert.equal(events.at(-1).error.code, "deadline_exceeded");
});

test("connect: the client's own timeout", async () => {
  const events = await run(watch({ count: 10, intervalMs: 50 }, { timeoutMs: 120 }));
  assert.deepEqual([events.at(-1).kind, events.at(-1).reason], ["error", "timeout"]);
});

test("connect: an unknown method is a non-200 end", async () => {
  const events = await run({ ...watch({}), url: `${base}/notes.v1.NotesService/Nope` });
  assert.equal(events.at(-1).kind, "end");
  // Vanguard, which holds "/", answers an unknown Connect stream path itself.
  assert.equal(events.at(-1).status, 505);
});

test("grpc-gateway NDJSON on the implicit route: results then the error line", async () => {
  const events = await run({
    url: `${base}/gateway/notes.v1.NotesService/WatchNotes`,
    headers: [["Content-Type", "application/json"]],
    body: JSON.stringify({ count: 2, intervalMs: 10, fail: true }),
    framing: "ndjson",
  });
  assert.deepEqual(events.filter((e) => e.kind === "message").map((e) => JSON.parse(e.json).index), ["1", "2"]);
  assert.equal(events.at(-1).error.code, 9);
  assert.equal(events.at(-1).error.details[0]["@type"], "type.googleapis.com/google.rpc.ErrorInfo");
});
