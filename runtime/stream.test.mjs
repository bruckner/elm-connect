// node --test runtime/
import { test } from "node:test";
import assert from "node:assert/strict";
import { createStreams, envelope, parser } from "./stream.js";

const utf8 = new TextEncoder();
const bytes = (s) => utf8.encode(s);
const join = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
};
const frame = (flags, json) => {
  const e = envelope(json);
  e[0] = flags;
  return e;
};

// Every way of cutting `body` into chunks: one chunk, every byte alone, and
// every single split point.
function splits(body) {
  const out = [[body], Array.from(body, (b) => Uint8Array.of(b))];
  for (let i = 1; i < body.length; i++) out.push([body.subarray(0, i), body.subarray(i)]);
  return out;
}

function parseAll(framing, chunks) {
  const p = parser(framing);
  const frames = [];
  for (const c of chunks) frames.push(...p.push(c));
  frames.push(...p.finish());
  return frames;
}

function eachSplit(framing, body, expected) {
  for (const chunks of splits(body)) {
    assert.deepEqual(parseAll(framing, chunks), expected, `split into ${chunks.map((c) => c.length)}`);
  }
}

const note = '{"name":"notes/1","body":"héllo, [wörld] {\\"x\\"} 🎉"}';
const note2 = '{"name":"notes/2"}';
const msg = (json) => ({ kind: "message", json });
const ok = { kind: "end", error: null, metadata: {} };

test("connect: messages then a clean end, at every split", () => {
  const body = join(frame(0, note), frame(0, note2), frame(2, '{"metadata":{"x-t":["1"]}}'));
  eachSplit("connect", body, [msg(note), msg(note2), { kind: "end", error: null, metadata: { "x-t": ["1"] } }]);
});

test("connect: end-stream with an error and details", () => {
  const error = { code: "failed_precondition", message: "stop", details: [{ type: "google.rpc.ErrorInfo", value: "CgE=" }] };
  const body = join(frame(0, note2), frame(2, JSON.stringify({ error })));
  eachSplit("connect", body, [msg(note2), { kind: "end", error, metadata: {} }]);
});

test("connect: an empty end-stream object is a clean end", () => {
  assert.deepEqual(parseAll("connect", [frame(2, "{}")]), [ok]);
});

test("connect: a compressed message is refused", () => {
  assert.throws(() => parseAll("connect", [frame(1, note)]), { reason: "compressed" });
});

test("connect: a body without end-stream is truncated", () => {
  assert.throws(() => parseAll("connect", [frame(0, note)]), { reason: "truncated", message: /without an end-stream/ });
  assert.throws(() => parseAll("connect", [frame(0, note).subarray(0, 8)]), { reason: "truncated", message: /inside a message/ });
});

test("connect: data after end-stream is a protocol error", () => {
  assert.throws(() => parseAll("connect", [join(frame(2, "{}"), frame(0, note))]), { reason: "protocol" });
});

test("ndjson (grpc-gateway): result lines and a final error", () => {
  const status = { code: 9, message: "stop", details: [] };
  const body = bytes(`{"result":${note}}\n{"result":${note2}}\n{"error":${JSON.stringify(status)}}\n`);
  eachSplit("ndjson", body, [msg(JSON.stringify(JSON.parse(note))), msg(note2), { kind: "end", error: status, metadata: {} }]);
});

test("ndjson (grpc-gateway): EOF is a clean end, last line without newline", () => {
  eachSplit("ndjson", bytes(`{"result":${note2}}\n{"result":${note2}}`), [msg(note2), msg(note2), ok]);
});

test("ndjson-bare (Envoy): bare lines", () => {
  eachSplit("ndjson-bare", bytes(`${note}\n${note2}\n`), [msg(note), msg(note2), ok]);
});

test("array (Envoy): elements with brackets and commas inside strings", () => {
  eachSplit("array", bytes(`[${note}\n,${note2}]`), [msg(note), msg(note2), ok]);
  eachSplit("array", bytes("[]"), [ok]);
});

test("array (Envoy): a cut-off array is a protocol error", () => {
  assert.throws(() => parseAll("array", [bytes(`[${note}`)]), { reason: "protocol" });
});

test("sse (Envoy): data events, CRLF and multi-line data", () => {
  eachSplit("sse", bytes(`data: ${note}\n\n: comment\n\ndata: ${note2}\r\n\r\n`), [msg(note), msg(note2), ok]);
  eachSplit("sse", bytes('data: {"a":\ndata: 1}\n\n'), [msg('{"a":\n1}'), ok]);
  eachSplit("sse", bytes('data: {"a":\r\ndata: 1}\r\n\r\n'), [msg('{"a":\n1}'), ok]);
});

test("UTF-8 split inside a multi-byte sequence in every text framing", () => {
  const body = bytes(`${note}\n`);
  const cut = body.indexOf(0xf0) + 2; // inside the 4-byte emoji
  assert.deepEqual(parseAll("ndjson-bare", [body.subarray(0, cut), body.subarray(cut)]), [msg(note), ok]);
});

// The client against a fake fetch whose body is a ReadableStream of chunks.
function fakeFetch(status, chunks, { delayMs = 0, headers = {} } = {}) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, init });
    let i = 0;
    const body = new ReadableStream({
      async pull(controller) {
        if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
        if (init.signal.aborted) return controller.error(new DOMException("aborted", "AbortError"));
        if (i < chunks.length) controller.enqueue(chunks[i++]);
        else controller.close();
      },
    });
    return new Response(body, { status, headers });
  };
  return { impl, calls };
}

function collect() {
  const events = [];
  let resolve;
  const done = new Promise((r) => (resolve = r));
  const emit = (e) => {
    events.push(e);
    if (e.kind === "end" || e.kind === "error") resolve();
  };
  return { events, emit, done };
}

test("client: envelopes the request and emits headers, messages and end", async () => {
  const { impl, calls } = fakeFetch(200, [join(frame(0, note2), frame(2, "{}"))], { headers: { "content-type": "application/connect+json" } });
  const { events, emit, done } = collect();
  createStreams(emit, impl).open("s", { url: "http://x/a.B/C", headers: [["Content-Type", "application/connect+json"]], body: "{}", framing: "connect" });
  await done;
  assert.deepEqual(Array.from(calls[0].init.body), [0, 0, 0, 0, 2, 123, 125]);
  assert.deepEqual(events, [
    { id: "s", kind: "headers", status: 200, headers: { "content-type": "application/connect+json" } },
    { id: "s", kind: "message", json: note2 },
    { id: "s", kind: "end", status: 200, error: null, metadata: {} },
  ]);
});

test("client: a non-200 answer ends with its body's error", async () => {
  const { impl } = fakeFetch(404, [bytes('{"error":{"code":5,"message":"gone"}}')]);
  const { events, emit, done } = collect();
  createStreams(emit, impl).open("s", { url: "u", body: "{}", framing: "ndjson" });
  await done;
  assert.deepEqual(events.at(-1), { id: "s", kind: "end", status: 404, error: { code: 5, message: "gone" }, metadata: {}, body: '{"error":{"code":5,"message":"gone"}}' });
});

test("client: cancel stops events", async () => {
  const { impl } = fakeFetch(200, [frame(0, note2), frame(0, note2), frame(2, "{}")], { delayMs: 20 });
  const events = [];
  const streams = createStreams((e) => events.push(e), impl);
  streams.open("s", { url: "u", body: "{}" });
  await new Promise((r) => setTimeout(r, 30));
  streams.cancel("s");
  await new Promise((r) => setTimeout(r, 100));
  assert.ok(events.length <= 2, JSON.stringify(events));
  assert.ok(!events.some((e) => e.kind === "end" || e.kind === "error"));
});

test("client: the timeout aborts and reports", async () => {
  const { impl } = fakeFetch(200, [frame(0, note2), frame(0, note2), frame(2, "{}")], { delayMs: 40 });
  const { events, emit, done } = collect();
  createStreams(emit, impl).open("s", { url: "u", body: "{}", timeoutMs: 60 });
  await done;
  assert.equal(events.at(-1).kind, "error");
  assert.equal(events.at(-1).reason, "timeout");
});

test("client: reopening an id replaces the old stream", async () => {
  const slow = fakeFetch(200, [frame(0, note), frame(2, "{}")], { delayMs: 50 });
  const { events, emit, done } = collect();
  const streams = createStreams(emit, slow.impl);
  streams.open("s", { url: "u", body: "{}" });
  streams.open("s", { url: "u", body: "{}" });
  await done;
  await new Promise((r) => setTimeout(r, 120));
  assert.equal(events.filter((e) => e.kind === "end").length, 1);
});
