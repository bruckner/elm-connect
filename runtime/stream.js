// Server streaming for elm-connect: the part an Elm package cannot ship.
//
// Elm's HTTP hands a program the whole body at once and its ports carry JSON,
// not bytes, so reading a stream as it arrives, framing the request and
// aborting it live here. Everything else (headers, auth, reconnecting,
// resuming, idle timeouts, decoding, errors) is Elm's: `Rpc.Stream` builds the
// value `open` takes and decodes the events this module emits.
//
//   const streams = createStreams((event) => app.ports.streamIn.send(event));
//   app.ports.streamOut.subscribe((command) => streams.run(command));
//
// Events, each with the `id` given to `open`:
//   { kind: "headers", status, headers }       the response's status and headers
//   { kind: "message", json }                  one message, as JSON text
//   { kind: "end", status, error, metadata }   the end; `error` is null or the
//                                              error object as the server sent it
//   { kind: "error", reason, message }         no answer: "network", "timeout",
//                                              "truncated" (a Connect body cut
//                                              short), "protocol" (a body that
//                                              breaks its framing), "compressed"
// A cancelled stream emits nothing more.

const END_STREAM = 0x02;
const COMPRESSED = 0x01;

/** A parser for one framing: `push(bytes)` and `finish()` return frames. */
export function parser(framing) {
  switch (framing) {
    case "connect":
      return connectParser();
    case "ndjson":
      return textParser(ndjsonSplit, gatewayFrame);
    case "ndjson-bare":
      return textParser(ndjsonSplit, bareFrame);
    case "array":
      return textParser(arraySplit(), bareFrame);
    case "sse":
      return textParser(sseSplit, bareFrame);
    default:
      throw new StreamError("protocol", `unknown framing ${framing}`);
  }
}

class StreamError extends Error {
  constructor(reason, message) {
    super(message);
    this.reason = reason;
  }
}

// Connect: 1 flag byte, 4-byte big-endian length, payload. Flag 0x02 marks the
// EndStreamResponse, which must come last.
function connectParser() {
  let buffer = new Uint8Array(0);
  let ended = false;
  const utf8 = new TextDecoder("utf-8", { fatal: true });
  return {
    push(chunk) {
      buffer = concat(buffer, chunk);
      const frames = [];
      while (buffer.length >= 5) {
        const flags = buffer[0];
        const length = new DataView(buffer.buffer, buffer.byteOffset, 5).getUint32(1);
        if (buffer.length < 5 + length) break;
        if (ended) throw new StreamError("protocol", "data after the end-stream message");
        if (flags & COMPRESSED) {
          throw new StreamError("compressed", "a compressed message arrived; this client asks for none");
        }
        const text = decode(utf8, buffer.subarray(5, 5 + length));
        buffer = buffer.subarray(5 + length);
        if (flags & END_STREAM) {
          ended = true;
          const end = parseJson(text);
          frames.push({ kind: "end", error: end.error ?? null, metadata: end.metadata ?? {} });
        } else {
          frames.push({ kind: "message", json: text });
        }
      }
      return frames;
    },
    finish() {
      if (buffer.length > 0) throw new StreamError("truncated", "the body ended inside a message");
      if (!ended) throw new StreamError("truncated", "the body ended without an end-stream message");
      return [];
    },
  };
}

// The transcoders' text framings: decode UTF-8 across chunks, split into
// pieces, turn each piece into a frame. A clean end has no marker.
function textParser(split, frame) {
  const utf8 = new TextDecoder("utf-8", { fatal: true });
  let text = "";
  let ended = false;
  const frames = (pieces) => {
    const out = [];
    for (const piece of pieces) {
      if (ended) throw new StreamError("protocol", "data after an error");
      const f = frame(piece);
      if (f.kind === "end") ended = true;
      out.push(f);
    }
    return out;
  };
  return {
    push(chunk) {
      text += decode(utf8, chunk, true);
      const { pieces, rest } = split(text, false);
      text = rest;
      return frames(pieces);
    },
    finish() {
      text += decode(utf8, new Uint8Array(0));
      const { pieces } = split(text, true);
      const out = frames(pieces);
      if (!ended) out.push({ kind: "end", error: null, metadata: {} });
      return out;
    },
  };
}

function ndjsonSplit(text, last) {
  const lines = text.split("\n");
  const rest = last ? "" : lines.pop();
  return { pieces: lines.map((l) => l.trim()).filter((l) => l !== ""), rest };
}

// grpc-gateway: {"result": message} per line, {"error": google.rpc.Status} last.
function gatewayFrame(line) {
  const value = parseJson(line);
  if (value && typeof value === "object" && "error" in value) {
    return { kind: "end", error: value.error, metadata: {} };
  }
  if (value && typeof value === "object" && "result" in value) {
    return { kind: "message", json: JSON.stringify(value.result) };
  }
  throw new StreamError("protocol", "a line with neither result nor error");
}

function bareFrame(json) {
  parseJson(json);
  return { kind: "message", json };
}

// Envoy's default: one JSON array, elements emitted as each closes. Scans
// strings and nesting so a comma or bracket inside a message is not a boundary.
function arraySplit() {
  let opened = false;
  let closed = false;
  return (text, last) => {
    const pieces = [];
    let i = 0;
    let start = -1;
    let depth = 0;
    let inString = false;
    let escaped = false;
    let consumed = 0;
    for (; i < text.length; i++) {
      const c = text[i];
      if (start >= 0) {
        if (inString) {
          if (escaped) escaped = false;
          else if (c === "\\") escaped = true;
          else if (c === '"') inString = false;
        } else if (c === '"') inString = true;
        else if (c === "{" || c === "[") depth++;
        else if (c === "}" || c === "]") {
          depth--;
          if (depth === 0) {
            pieces.push(text.slice(start, i + 1));
            start = -1;
            consumed = i + 1;
          }
        }
        continue;
      }
      if (/\s/.test(c) || (opened && c === ",")) {
        consumed = i + 1;
      } else if (!opened && c === "[") {
        opened = true;
        consumed = i + 1;
      } else if (opened && !closed && c === "]") {
        closed = true;
        consumed = i + 1;
      } else if (opened && !closed && (c === "{" || c === "[")) {
        start = i;
        depth = 1;
      } else {
        throw new StreamError("protocol", `unexpected ${JSON.stringify(c)} in a JSON array stream`);
      }
    }
    if (last && (start >= 0 || (opened && !closed) || !opened)) {
      throw new StreamError("protocol", "the body ended inside the JSON array");
    }
    return { pieces, rest: text.slice(consumed) };
  };
}

// Server-sent events: events end at a blank line; `data:` lines join with "\n".
function sseSplit(text, last) {
  // A trailing "\r" may be half of a "\r\n" the next chunk completes.
  const held = !last && text.endsWith("\r") ? "\r" : "";
  const normal = text.slice(0, text.length - held.length).replace(/\r\n?/g, "\n");
  const events = normal.split("\n\n");
  const rest = last ? "" : events.pop() + held;
  const pieces = [];
  for (const event of events) {
    const data = event
      .split("\n")
      .filter((line) => line.startsWith("data:"))
      .map((line) => line.slice(5).replace(/^ /, ""));
    if (data.length > 0) pieces.push(data.join("\n"));
  }
  return { pieces, rest };
}

function parseJson(text) {
  try {
    return JSON.parse(text);
  } catch (e) {
    throw new StreamError("protocol", `a frame is not JSON: ${e.message}`);
  }
}

function decode(utf8, bytes, stream = false) {
  try {
    return utf8.decode(bytes, { stream });
  } catch {
    throw new StreamError("protocol", "a frame is not UTF-8");
  }
}

function concat(a, b) {
  if (a.length === 0) return b;
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

/** The request body Connect sends: the message JSON in one envelope. */
export function envelope(json) {
  const payload = new TextEncoder().encode(json);
  const out = new Uint8Array(5 + payload.length);
  new DataView(out.buffer).setUint32(1, payload.length);
  out.set(payload, 5);
  return out;
}

/** An error answer read whole: its body's error object, or null for Elm to
 * infer one from the status. grpc-gateway wraps it in {"error": …}. */
function errorBody(text) {
  try {
    const value = JSON.parse(text);
    if (value && typeof value === "object") {
      if (value.error && typeof value.error === "object") return value.error;
      if ("code" in value) return value;
    }
  } catch {
    // not JSON: the status alone says what failed
  }
  return null;
}

/**
 * Streams keyed by id. `emit` receives every event; `fetchImpl` is for tests.
 */
export function createStreams(emit, fetchImpl = globalThis.fetch.bind(globalThis)) {
  const live = new Map();

  async function open(id, { url, method = "POST", headers = [], body = null, framing = "connect", timeoutMs = null, withCredentials = false }) {
    cancel(id);
    const controller = new AbortController();
    const entry = { controller, timedOut: false, timer: null };
    live.set(id, entry);
    const current = () => live.get(id) === entry;
    const send = (event) => {
      if (current()) emit({ id, ...event });
    };
    if (timeoutMs > 0) {
      entry.timer = setTimeout(() => {
        entry.timedOut = true;
        controller.abort();
      }, timeoutMs);
    }
    try {
      const response = await fetchImpl(url, {
        method,
        headers,
        body: body === null ? undefined : framing === "connect" ? envelope(body) : body,
        signal: controller.signal,
        credentials: withCredentials ? "include" : "same-origin",
      });
      const responseHeaders = {};
      response.headers.forEach((value, name) => {
        responseHeaders[name] = value;
      });
      send({ kind: "headers", status: response.status, headers: responseHeaders });
      if (response.status !== 200) {
        const text = await response.text();
        send({ kind: "end", status: response.status, error: errorBody(text), metadata: {}, body: text });
        return;
      }
      const frames = parser(framing);
      const reader = response.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        const out = done ? frames.finish() : frames.push(value);
        for (const frame of out) {
          if (!current()) return;
          send(frame.kind === "end" ? { status: 200, ...frame } : frame);
          if (frame.kind === "end") {
            controller.abort();
            return;
          }
        }
        if (done) return;
      }
    } catch (e) {
      if (entry.timedOut) send({ kind: "error", reason: "timeout", message: "the stream's timeout passed" });
      else if (e instanceof StreamError) {
        controller.abort();
        send({ kind: "error", reason: e.reason, message: e.message });
      } else if (!controller.signal.aborted) send({ kind: "error", reason: "network", message: String(e?.message ?? e) });
    } finally {
      clearTimeout(entry.timer);
      if (current()) live.delete(id);
    }
  }

  function cancel(id) {
    const entry = live.get(id);
    if (entry) {
      live.delete(id);
      clearTimeout(entry.timer);
      entry.controller.abort();
    }
  }

  /** A command from `Rpc.Stream.open` or `Rpc.Stream.cancel`. */
  function run(command) {
    if (command.cancel !== undefined) cancel(command.cancel);
    else open(command.id, command.open);
  }

  return { open, cancel, run };
}
