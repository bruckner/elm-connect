#!/usr/bin/env node
// The route fixtures, live: every fixture in conformance/routes/ is sent by
// the runtime over the Transcode transport to the example server, which
// serves routes.v1.Routes under a transcoder, Vanguard at its root and
// grpc-gateway under /gateway, and echoes each request as the transcoder
// decoded it. For each fixture it checks
//
//   (a) the request the runtime made: verb, path, query pairs (as sent,
//       percent-encoded, in order), body, and a fixture's headers;
//   (b) the server's answer: HTTP 200, and its echo of the request equal
//       to the fixture's request, both read as proto3 JSON (normalize);
//   (c) the runtime's reading of that answer: `ok`, equal to the echo.
//
// A fixture the transcoder rejects or echoes differently is recorded in its
// known-divergent file (known-divergent-vanguard.json,
// known-divergent-gateway.json) with the transcoder's answer, and the run
// stays green while that answer holds; one that starts agreeing fails until
// its entry is removed. The bindings the transcoder cannot serve beside the
// others are listed there too, and must match the server's GET
// <prefix>/routes/layers. Its probes are requests the runtime does not make
// (an unknown query parameter, a verb without a route), sent with fetch,
// whose answers must match the ones recorded, so that where the transcoders
// differ beyond the fixtures is asserted too.
//
//   node routes.mjs --serve path/to/server
//   node routes.mjs --server http://127.0.0.1:8080
//   node routes.mjs --serve path/to/server --prefix /gateway --known known-divergent-gateway.json
//
// Formats: conformance/README.md, "Live verification".

import { readFile, readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createRunner, mismatches, serve } from "./run.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const routesDir = path.join(here, "..", "routes");

// SCHEMA
//
// Enough of routes.proto to read its requests as proto3 JSON: messages
// (nested ones included), their fields, enums and the service's methods.

export function parseProto(source) {
  const tokens = source
    .replace(/\/\/.*$/gm, "")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .match(/"(?:[^"\\]|\\.)*"|[A-Za-z_][\w.]*|-?\d+|[{}()\[\];=<>,:]/g);
  const schema = { messages: {}, enums: {}, methods: {}, package: "" };
  let at = 0;
  const next = () => tokens[at++];
  const expect = (t) => {
    if (tokens[at] !== t) throw new Error(`routes.proto: expected ${t} at ${tokens.slice(at, at + 5).join(" ")}`);
    at++;
  };
  // Skip to the end of a statement or a balanced block.
  const skip = () => {
    let depth = 0;
    for (;;) {
      const t = next();
      if (t === "{") depth++;
      else if (t === "}" && --depth === 0) return;
      else if (t === ";" && depth === 0) return;
    }
  };
  const parseEnum = (scope) => {
    const name = `${scope}.${next()}`;
    expect("{");
    const values = {};
    while (tokens[at] !== "}") {
      if (tokens[at] === "option" || tokens[at] === "reserved") {
        skip();
        continue;
      }
      const value = next();
      expect("=");
      values[Number(next())] = value;
      while (next() !== ";");
    }
    expect("}");
    schema.enums[name] = values;
  };
  // A map field's value type is given; its key type is set after.
  const parseField = (fields, label, oneof, valueType) => {
    const type = valueType ?? next();
    const name = next();
    expect("=");
    next();
    if (tokens[at] === "[") while (next() !== "]");
    expect(";");
    fields.push({ name, json: jsonName(name), type, repeated: label === "repeated", presence: label === "optional" || oneof, scope: null });
  };
  const parseMessage = (scope) => {
    const name = `${scope}.${next()}`;
    const fields = [];
    expect("{");
    while (tokens[at] !== "}") {
      const t = tokens[at];
      if (t === "message") {
        at++;
        parseMessage(name);
      } else if (t === "enum") {
        at++;
        parseEnum(name);
      } else if (t === "oneof") {
        at += 2;
        expect("{");
        while (tokens[at] !== "}") parseField(fields, null, true);
        expect("}");
      } else if (t === "option" || t === "reserved") {
        skip();
      } else if (t === "map") {
        at++;
        expect("<");
        const key = next();
        expect(",");
        const value = next();
        expect(">");
        parseField(fields, null, false, value);
        fields.at(-1).mapKey = key;
      } else if (t === "repeated" || t === "optional") {
        at++;
        parseField(fields, t, false);
      } else {
        parseField(fields, null, false);
      }
    }
    expect("}");
    for (const f of fields) f.scope = name;
    schema.messages[name] = fields;
  };
  while (at < tokens.length) {
    const t = next();
    if (t === "package") {
      schema.package = next();
      expect(";");
    } else if (t === "message") parseMessage(schema.package ? `.${schema.package}` : "");
    else if (t === "enum") parseEnum(schema.package ? `.${schema.package}` : "");
    else if (t === "service") {
      const service = `${schema.package}.${next()}`;
      expect("{");
      while (tokens[at] !== "}") {
        if (tokens[at] !== "rpc") {
          skip();
          continue;
        }
        at++;
        const method = next();
        expect("(");
        const input = next();
        expect(")");
        expect("returns");
        expect("(");
        const output = next();
        expect(")");
        schema.methods[`${service}.${method}`] = { input, output };
        if (tokens[at] === "{") skip();
        else expect(";");
      }
      expect("}");
    } else if (t !== ";") {
      at--;
      skip();
    }
  }
  return schema;
}

function jsonName(name) {
  return name.replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase());
}

// Resolve a type name as protoc does: from the innermost scope outwards.
function resolve(schema, type, scope) {
  if (type.startsWith(".")) return type;
  const parts = scope.split(".");
  for (let n = parts.length; n >= 0; n--) {
    const candidate = `${parts.slice(0, n).join(".")}.${type}`;
    if (candidate in schema.messages || candidate in schema.enums) return candidate;
  }
  return `.${type}`;
}

// NORMALIZATION
//
// Two proto3 JSON writers may write the same message differently: one
// leaves out a field at its default and another writes it (Vanguard writes
// every field), 64-bit integers as strings or numbers, enums by name or
// number, a duration with any number of fractional digits, bytes with or
// without padding. normalize rewrites a message to one form: a field
// without presence at its default is left out, a field with presence
// (optional, a oneof member, a message) kept when set, null is unset,
// 64-bit integers are decimal strings, enums names, bytes padded standard
// base64, durations and timestamps a count of nanoseconds. Keys are JSON
// names; a proto name is accepted.

const int32s = new Set(["int32", "sint32", "sfixed32", "uint32", "fixed32"]);
const int64s = new Set(["int64", "sint64", "sfixed64", "uint64", "fixed64"]);
const wrappers = {
  ".google.protobuf.DoubleValue": "double",
  ".google.protobuf.FloatValue": "float",
  ".google.protobuf.Int64Value": "int64",
  ".google.protobuf.UInt64Value": "uint64",
  ".google.protobuf.Int32Value": "int32",
  ".google.protobuf.UInt32Value": "uint32",
  ".google.protobuf.BoolValue": "bool",
  ".google.protobuf.StringValue": "string",
  ".google.protobuf.BytesValue": "bytes",
};

export function normalize(schema, type, value) {
  const fields = schema.messages[type];
  if (!fields) throw new Error(`no message ${type}`);
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${type}: not an object: ${JSON.stringify(value)}`);
  }
  const known = new Set(fields.flatMap((f) => [f.json, f.name]));
  const unknown = Object.keys(value).filter((k) => !known.has(k));
  if (unknown.length > 0) throw new Error(`${type}: unknown fields ${unknown.join(", ")}`);
  const out = {};
  for (const f of fields) {
    const raw = f.json in value ? value[f.json] : value[f.name];
    if (raw === undefined || raw === null) continue;
    const t = int32s.has(f.type) || int64s.has(f.type) || ["double", "float", "bool", "string", "bytes"].includes(f.type)
      ? f.type
      : resolve(schema, f.type, f.scope);
    if (f.mapKey) {
      if (typeof raw !== "object" || Array.isArray(raw)) throw new Error(`${type}.${f.name}: not an object`);
      const entries = Object.entries(raw).map(([k, v]) => [mapKey(f.mapKey, k), scalar(schema, t, v, `${type}.${f.name}`)]);
      if (entries.length > 0) out[f.json] = Object.fromEntries(entries);
      continue;
    }
    if (f.repeated) {
      if (!Array.isArray(raw)) throw new Error(`${type}.${f.name}: not an array`);
      if (raw.length > 0) out[f.json] = raw.map((v) => scalar(schema, t, v, `${type}.${f.name}`));
      continue;
    }
    const v = scalar(schema, t, raw, `${type}.${f.name}`);
    const message = t in schema.messages || t.startsWith(".google.protobuf.");
    if (f.presence || message || !isDefault(schema, t, v)) out[f.json] = v;
  }
  return out;
}

// A map key as proto3 JSON writes it: an integer key in canonical decimal.
function mapKey(type, key) {
  return int32s.has(type) || int64s.has(type) ? BigInt(key).toString() : key;
}

function isDefault(schema, type, v) {
  if (type in schema.enums) return v === schema.enums[type][0];
  return v === 0 || v === "0" || v === "" || v === false;
}

function scalar(schema, type, v, where) {
  if (int32s.has(type)) return Number(v);
  if (int64s.has(type)) return BigInt(v).toString();
  if (type === "double" || type === "float") return typeof v === "string" && !/^-?[\d.eE+-]+$/.test(v) ? v : Number(v);
  if (type === "bool" || type === "string") return v;
  if (type === "bytes") return Buffer.from(v.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("base64");
  if (type in schema.enums) return typeof v === "number" ? (schema.enums[type][v] ?? v) : v;
  if (type in schema.messages) return normalize(schema, type, v);
  if (type in wrappers) return scalar(schema, wrappers[type], v, where);
  if (type === ".google.protobuf.Duration") return durationNanos(v);
  if (type === ".google.protobuf.Timestamp") return timestampNanos(v);
  if (type === ".google.protobuf.FieldMask") return v;
  throw new Error(`${where}: no proto3 JSON reading of ${type}`);
}

function durationNanos(text) {
  const m = /^(-?)(\d+)(?:\.(\d{1,9}))?s$/.exec(text);
  if (!m) throw new Error(`not a duration: ${text}`);
  const nanos = BigInt(m[2]) * 1000000000n + BigInt((m[3] ?? "").padEnd(9, "0"));
  return `${m[1] && nanos !== 0n ? "-" : ""}${nanos}ns`;
}

function timestampNanos(text) {
  const m = /^(.*T\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)$/.exec(text);
  const ms = m && Date.parse(m[1] + m[3]);
  if (!m || Number.isNaN(ms)) throw new Error(`not a timestamp: ${text}`);
  return `${BigInt(ms) * 1000000n + BigInt((m[2] ?? "").padEnd(9, "0"))}ns`;
}

// CHECKS

// The fields of the response that carry the request as proto3 JSON, for a
// method whose response is not its request type (examples/notes/server
// routes.go).
const echoFields = { ".routes.v1.Message": "text", ".routes.v1.Resource": "displayName" };

function typeOf(schema, name) {
  return resolve(schema, name, `.${schema.package}`);
}

// What the server echoed as the request it decoded, from its answer's JSON.
function echoOf(schema, method, answer) {
  const input = typeOf(schema, method.input);
  const output = typeOf(schema, method.output);
  if (input === output) return answer;
  return JSON.parse(answer[echoFields[output]] ?? "{}");
}

// The problems with one fixture's live call, as [what, expected, actual],
// and notes on what passed only as the fixtures compare.
export function check(schema, fixture, result, baseUrl) {
  const problems = [];
  const notes = [];
  const fail = (what, expected, actual) => problems.push([what, expected, actual]);
  const method = schema.methods[fixture.method];
  const input = typeOf(schema, method.input);
  const request = result.trace?.request;
  if (!request) {
    fail("trace", "a trace", result);
    return { problems, notes };
  }

  // (a) The request.
  const verb = fixture.rule ? fixture.rule.verb : "POST";
  if (request.method !== verb) fail("verb", verb, request.method);
  if (!request.url.startsWith(baseUrl)) fail("url", `${baseUrl}…`, request.url);
  const [pathPart, queryPart] = splitOnce(request.url.slice(baseUrl.length), "?");
  if (pathPart !== fixture.expect.path) fail("path", fixture.expect.path, pathPart);
  const query = queryPart === undefined ? [] : queryPart.split("&").map((pair) => splitOnce(pair, "=").map((s) => s ?? ""));
  if (JSON.stringify(query) !== JSON.stringify(fixture.expect.query)) fail("query", fixture.expect.query, query);
  if (fixture.expect.body === null) {
    if (request.body !== null) fail("body", null, request.body);
  } else {
    // As the fixtures' own checks compare bodies (tests/Replay.elm): nulls
    // and defaults dropped, {} included. Where that hides a difference proto3
    // JSON does not (an empty message is a set one), it is noted.
    let sent;
    try {
      sent = JSON.parse(request.body);
    } catch (e) {
      fail("body", fixture.expect.body, `${request.body} (${e.message})`);
    }
    if (sent !== undefined) {
      if (!sameJson(pruned(sent), pruned(fixture.expect.body))) fail("body", fixture.expect.body, sent);
      else {
        const bodyType = bodyTypeOf(schema, input, fixture.rule);
        const [a, b] = [normalize(schema, bodyType, sent), normalize(schema, bodyType, fixture.expect.body)];
        if (!sameJson(a, b)) notes.push(`the body sent, ${JSON.stringify(sent)}, sets a message the fixture's, ${JSON.stringify(fixture.expect.body)}, leaves unset`);
      }
    }
  }
  for (const header of fixture.expect.headers ?? []) {
    if (!request.headers.some(([k, v]) => k.toLowerCase() === header[0].toLowerCase() && v === header[1])) {
      fail(`header ${header[0]}`, header, request.headers);
    }
  }

  // (b) The server's answer.
  const exchange = result.wire?.at(-1);
  if (result.trace.httpStatus !== 200) fail("HTTP status", 200, result.trace.httpStatus);
  if (!exchange || exchange.status !== 200) {
    fail("answer", "HTTP 200", exchange ? { status: exchange.status, body: exchange.responseBody } : null);
    return { problems, notes };
  }
  const want = normalize(schema, input, fixture.request);
  if (verb === "HEAD") {
    // A HEAD answer has no body (RFC 9110 §9.3.2), so there is no echo; the
    // runtime reads the empty 2xx as {}.
    if (exchange.responseBody !== "") fail("HEAD answer body", "", exchange.responseBody);
    const output = typeOf(schema, method.output);
    if (!result.result?.ok || !sameJson(normalize(schema, output, result.result.ok), {})) {
      fail("result", { ok: {} }, result.result);
    }
    return { problems, notes };
  }
  let answer;
  try {
    answer = JSON.parse(exchange.responseBody);
    const echoed = normalize(schema, input, echoOf(schema, method, answer));
    if (!sameJson(echoed, want)) fail("echo", want, echoed);
  } catch (e) {
    fail("echo", want, `${exchange.responseBody} (${e.message})`);
    return { problems, notes };
  }

  // (c) The runtime's reading of it.
  if (!result.result || !("ok" in result.result)) {
    fail("result", "ok", result.result);
  } else {
    const output = typeOf(schema, method.output);
    try {
      const read = normalize(schema, output, result.result.ok);
      const sent = normalize(schema, output, answer);
      if (!sameJson(read, sent)) fail("result.ok", sent, read);
    } catch (e) {
      fail("result.ok", answer, `${JSON.stringify(result.result.ok)} (${e.message})`);
    }
  }
  return { problems, notes };
}

function bodyTypeOf(schema, input, rule) {
  if (!rule || rule.body === "*") return input;
  const field = schema.messages[input].find((f) => f.name === rule.body);
  return resolve(schema, field.type, field.scope);
}

function splitOnce(text, separator) {
  const at = text.indexOf(separator);
  return at < 0 ? [text, undefined] : [text.slice(0, at), text.slice(at + 1)];
}

// A body as the fixtures compare it: nulls and default values ("", 0,
// false, "0", [], {}) dropped, all the way down.
function pruned(v) {
  if (Array.isArray(v)) return v.map(pruned);
  if (v !== null && typeof v === "object") {
    return Object.fromEntries(
      Object.entries(v)
        .map(([k, x]) => [k, pruned(x)])
        .filter(([, x]) => !isPrunable(x)),
    );
  }
  return v;
}

function isPrunable(x) {
  if (x === null || x === "" || x === 0 || x === false || x === "0") return true;
  if (Array.isArray(x)) return x.length === 0;
  return typeof x === "object" && Object.keys(x).length === 0;
}

function sameJson(a, b) {
  return JSON.stringify(sortKeys(a)) === JSON.stringify(sortKeys(b));
}

function sortKeys(v) {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v !== null && typeof v === "object") {
    return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])]));
  }
  return v;
}

// RUNNING

// Run every fixture against the server at url. Gives the names that failed.
// url is the transcoder's: the server's with its prefix, if any.
export async function runFixtures(runner, url, { log = console.log, known } = {}) {
  const schema = parseProto(await readFile(path.join(routesDir, "routes.proto"), "utf8"));
  const failed = [];

  // Where each binding is served, and the bindings served apart, which
  // must be the ones the known-divergent file lists.
  const layers = await (await fetch(`${url}/routes/layers`)).json();
  const prefixes = new Map(layers.map((b) => [`${b.method} ${b.binding}`, b.prefix]));
  const apart = layers.filter((b) => b.layer > 0).map((b) => `${b.method} ${b.binding} ${b.prefix}`);
  const listed = known.servedApart.map((b) => `${b.method} ${b.binding} ${b.prefix}`);
  if (JSON.stringify(apart.sort()) !== JSON.stringify(listed.sort())) {
    failed.push("served apart");
    log(`FAIL  bindings served apart\n        known-divergent ${JSON.stringify(listed)}\n        server          ${JSON.stringify(apart)}`);
  } else {
    for (const b of layers.filter((b) => b.layer > 0)) {
      log(`apart ${b.method} binding ${b.binding} under ${b.prefix}: ${b.reason}`);
    }
  }

  for (const probe of known.probes ?? []) {
    const name = `probe: ${probe.name}`;
    const { method, path: target, body } = probe.request;
    const res = await fetch(url + target, { method, body: body === undefined ? undefined : JSON.stringify(body) });
    const text = await res.text();
    let parsed = text;
    try {
      parsed = JSON.parse(text);
    } catch {}
    const answer = { status: res.status, body: parsed };
    const differs = mismatches(probe.observed, answer);
    if (differs.length > 0) {
      failed.push(name);
      log(`FAIL  ${name}\n        answers otherwise than the known-divergent file records`);
      report(log, differs, answer);
    } else {
      log(`ok    ${name}`);
    }
  }

  const files = (await readdir(routesDir)).filter((f) => f.endsWith(".json")).sort();
  for (const file of files) {
    const { fixtures } = JSON.parse(await readFile(path.join(routesDir, file), "utf8"));
    for (const fixture of fixtures) {
      const name = `${file}: ${fixture.name}`;
      const dot = fixture.method.lastIndexOf(".");
      const prefix = fixture.binding === null ? "" : (prefixes.get(`${fixture.method} ${fixture.binding}`) ?? "");
      const baseUrl = url + prefix;
      const result = await runner.call({
        id: name,
        service: fixture.method.slice(0, dot),
        method: fixture.method.slice(dot + 1),
        request: fixture.request,
        transport: "transcode",
        config: { baseUrl },
        binding: fixture.binding,
      });
      const { problems, notes } = check(schema, fixture, result, baseUrl);
      const divergence = known.fixtures.find((d) => d.file === file && d.fixture === fixture.name);
      if (divergence) {
        const differs = mismatches(divergence.observed, result);
        if (problems.length === 0) {
          failed.push(name);
          log(`FAIL  ${name}\n        agrees now: remove it from the known-divergent file`);
        } else if (differs.length > 0) {
          failed.push(name);
          log(`FAIL  ${name}\n        diverges otherwise than the known-divergent file records`);
          report(log, problems.concat(differs), result);
        } else {
          log(`known ${name}: see the known-divergent file`);
        }
      } else if (problems.length === 0) {
        log(`ok    ${name}${prefix ? ` (under ${prefix})` : ""}`);
        for (const note of notes) log(`note  ${name}: ${note}`);
      } else {
        failed.push(name);
        log(`FAIL  ${name}`);
        report(log, problems, result);
      }
    }
  }
  return failed;
}

function report(log, problems, result) {
  for (const [what, want, have] of problems) {
    log(`        ${what}\n          expected ${JSON.stringify(want)}\n          actual   ${JSON.stringify(have)}`);
  }
  log(`        result ${JSON.stringify(result)}`);
}

async function main(argv) {
  const args = { known: path.join(here, "known-divergent-vanguard.json"), prefix: "" };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--server") args.server = argv[++i];
    else if (arg === "--serve") args.serve = argv[++i];
    else if (arg === "--elm") args.elm = argv[++i];
    else if (arg === "--known") args.known = argv[++i];
    else if (arg === "--prefix") args.prefix = argv[++i];
    else {
      console.error(`unknown argument ${arg}`);
      process.exit(2);
    }
  }
  if (!args.server && !args.serve) {
    console.error("usage: routes.mjs (--server URL | --serve BINARY) [--elm build/elm.js] [--prefix /PATH] [--known known-divergent-vanguard.json]");
    process.exit(2);
  }
  const known = JSON.parse(await readFile(args.known, "utf8"));
  const server = args.serve ? await serve(args.serve) : { url: args.server, stop: async () => {} };
  let failed;
  try {
    const runner = await createRunner({ elm: args.elm });
    failed = await runFixtures(runner, server.url + args.prefix, { known });
  } finally {
    await server.stop();
  }
  if (failed.length > 0) {
    console.error(`\n${failed.length} fixture(s) failed: ${failed.join("; ")}`);
    process.exit(1);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main(process.argv.slice(2));
}
