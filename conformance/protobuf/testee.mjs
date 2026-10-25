#!/usr/bin/env node
// The protobuf conformance suite's testee: conformance_test_runner starts it
// and writes ConformanceRequest messages to its stdin, each prefixed by its
// length as a 4-byte little-endian integer, and reads a ConformanceResponse
// for each from its stdout, framed the same way (protocolbuffers/protobuf,
// conformance/conformance.proto). Each request is handed to the Elm worker
// (src/Testee.elm, compiled to build/testee.js) over a port and answered from
// its reply. The messages are read and written here by hand: they are a few
// fields of four wire types.
//
//   conformance_test_runner --enforce_recommended --failure_list FAILURES node testee.mjs

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));

const FORMATS = { 0: "unspecified", 1: "protobuf", 2: "json", 3: "jspb", 4: "text" };

function readVarint(buf, at) {
  let value = 0n;
  let shift = 0n;
  for (;;) {
    const b = buf[at++];
    value |= BigInt(b & 0x7f) << shift;
    if (b < 0x80) return [value, at];
    shift += 7n;
  }
}

// The fields of a ConformanceRequest the testee needs.
function parseRequest(buf) {
  const request = { inputFormat: "none", payload: "", outputFormat: "unspecified", messageType: "" };
  let at = 0;
  while (at < buf.length) {
    let key;
    [key, at] = readVarint(buf, at);
    const number = Number(key >> 3n);
    const wire = Number(key & 7n);
    if (wire === 0) {
      let v;
      [v, at] = readVarint(buf, at);
      if (number === 3) request.outputFormat = FORMATS[Number(v)] ?? `format ${v}`;
    } else if (wire === 2) {
      let length;
      [length, at] = readVarint(buf, at);
      const bytes = buf.subarray(at, at + Number(length));
      at += Number(length);
      if (number === 1) [request.inputFormat, request.payload] = ["protobuf", Buffer.from(bytes).toString("base64")];
      else if (number === 2) [request.inputFormat, request.payload] = ["json", bytes.toString("utf8")];
      else if (number === 7) request.inputFormat = "jspb";
      else if (number === 8) request.inputFormat = "text";
      else if (number === 4) request.messageType = bytes.toString("utf8");
    } else if (wire === 5) at += 4;
    else if (wire === 1) at += 8;
    else throw new Error(`ConformanceRequest: wire type ${wire}`);
  }
  return request;
}

function varint(n) {
  const out = [];
  while (n >= 0x80) {
    out.push((n & 0x7f) | 0x80);
    n >>>= 7;
  }
  out.push(n);
  return Buffer.from(out);
}

// A ConformanceResponse with one member of its `result` oneof.
const RESULT = { parseError: 1, runtimeError: 2, protobuf: 3, json: 4, skipped: 5, serializeError: 6 };
function encodeResponse(kind, payload) {
  const body = kind === "protobuf" ? Buffer.from(payload, "base64") : Buffer.from(payload, "utf8");
  return Buffer.concat([varint((RESULT[kind] << 3) | 2), varint(body.length), body]);
}

const scope = {};
new Function(readFileSync(path.join(here, "build", "testee.js"), "utf8")).call(scope);
const app = scope.Elm.Testee.init();
await new Promise((resolve) => setTimeout(resolve, 0));
const waiting = new Map();
app.ports.responses.subscribe((r) => {
  const resolve = waiting.get(r.id);
  waiting.delete(r.id);
  resolve(r);
});

let next = 0;
function ask(request) {
  const id = next++;
  return new Promise((resolve) => {
    waiting.set(id, resolve);
    app.ports.requests.send({ id, ...request });
  });
}

async function respond(buf) {
  const request = parseRequest(buf);
  if (request.messageType === "conformance.FailureSet") return encodeResponse("protobuf", "");
  // TESTEE_FAIL_ALL=1 fails every case the testee would run, so the runner's
  // failure list names them all: the suite's totals by category. (A
  // runtime_error makes the runner abort on some cases.)
  if (process.env.TESTEE_FAIL_ALL === "1") {
    const r = await ask(request);
    if (r.kind === "skipped") return encodeResponse("skipped", r.payload);
    // A payload in the format asked for that is no message at all: wrong
    // for a case that expects a message and for one that expects an error.
    return request.outputFormat === "json" ? encodeResponse("json", "!") : encodeResponse("protobuf", "/w==");
  }
  try {
    const r = await ask(request);
    return encodeResponse(r.kind, r.payload);
  } catch (e) {
    return encodeResponse("runtimeError", String(e?.stack ?? e));
  }
}

let buffered = Buffer.alloc(0);
for await (const chunk of process.stdin) {
  buffered = Buffer.concat([buffered, chunk]);
  while (buffered.length >= 4) {
    const size = buffered.readUInt32LE(0);
    if (buffered.length < 4 + size) break;
    const response = await respond(buffered.subarray(4, 4 + size));
    buffered = buffered.subarray(4 + size);
    const prefix = Buffer.alloc(4);
    prefix.writeUInt32LE(response.length);
    process.stdout.write(Buffer.concat([prefix, response]));
  }
}
