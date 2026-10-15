#!/usr/bin/env node
// The client under test for the Connect conformance suite
// (github.com/connectrpc/conformance, `connectconformance --mode client`):
// reads ClientCompatRequest messages from stdin, makes each call with the
// runtime through the live runner (run.mjs), and writes a
// ClientCompatResponse for each to stdout. Both streams are protobuf binary,
// each message prefixed by its length as a 4-byte big-endian integer.
//
//   connectconformance --mode client --conf conformance.yaml \
//     --known-failing @known-failing.txt -- node conformance.mjs [--send MODE]
//
// MODE is how the runner sends each call (an envelope's `send`): `halves`,
// the default, through the runtime's pure halves (Rpc.request, elm/http,
// Rpc.response), which is the one way an application gets an answer's status
// and headers; or `sendTraced`, `send` or `task`, which give the response or
// the error only. What is reported is what the mode gives an application: the
// decoded response or the `Rpc.Error`, and with `halves` the answer's status
// and headers. The runner's `wire` log is never read. What the runtime cannot
// do is in known-failing.txt, and what only the halves can in
// known-failing-send.txt.
//
// Formats and the reasoning: conformance/README.md, "The Connect conformance
// suite"; design section 7.

import { create, fromBinary, fromJson, toBinary, toJson, createRegistry } from "@bufbuild/protobuf";
import { anyUnpack, AnySchema } from "@bufbuild/protobuf/wkt";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createRunner } from "./run.mjs";
import {
  ClientCompatRequestSchema,
  ClientCompatResponseSchema,
  file_connectrpc_conformance_v1_client_compat,
} from "./suite/js/connectrpc/conformance/v1/client_compat_pb.js";
import { Code, Codec, Compression, HTTPVersion, Protocol } from "./suite/js/connectrpc/conformance/v1/config_pb.js";
import {
  ConformancePayloadSchema,
  IdempotentUnaryRequestSchema,
  IdempotentUnaryResponseSchema,
  UnaryRequestSchema,
  UnaryResponseSchema,
  UnimplementedRequestSchema,
  UnimplementedResponseSchema,
  file_connectrpc_conformance_v1_service,
} from "./suite/js/connectrpc/conformance/v1/service_pb.js";

const here = path.dirname(fileURLToPath(import.meta.url));

const service = "connectrpc.conformance.v1.ConformanceService";

// The unary methods, which are the ones elm-connect generates, with their
// request and response types.
const methods = {
  Unary: { request: UnaryRequestSchema, response: UnaryResponseSchema },
  IdempotentUnary: { request: IdempotentUnaryRequestSchema, response: IdempotentUnaryResponseSchema },
  Unimplemented: { request: UnimplementedRequestSchema, response: UnimplementedResponseSchema },
};

// Every message an Any in a request or an answer may hold: the suite's own,
// and the well-known types they import.
const registry = createRegistry(file_connectrpc_conformance_v1_service, file_connectrpc_conformance_v1_client_compat);

// The ClientCompatResponse for one request.
async function answer(runner, send, request) {
  const unsupported = refusal(request);
  if (unsupported) return failed(request, unsupported);
  const types = methods[request.method];

  const packed = request.requestMessages[0];
  const message = anyUnpack(packed, types.request);
  if (message === undefined) {
    return failed(request, `request message is a ${packed.typeUrl}, not a ${types.request.typeName}`);
  }

  const headers = request.requestHeaders.flatMap((h) => h.value.map((v) => [h.name, v]));
  const config = {
    baseUrl: `http://${request.host.includes(":") ? `[${request.host}]` : request.host}:${request.port}`,
    headers,
    timeout: request.timeoutMs ?? null,
    useGet: request.useGetHttpMethod,
  };
  const outcome = await runner.call({
    id: request.testName,
    service,
    method: request.method,
    request: toJson(types.request, message, { registry }),
    transport: "connect",
    config,
    send,
  });

  const result = outcome.result;
  if (result.runner !== undefined) return failed(request, `the runner refused the call: ${result.runner}`);

  const { responseHeaders, responseTrailers } = metadata(outcome.response);
  const response = {
    responseHeaders,
    responseTrailers,
    payloads: [],
    httpStatusCode: outcome.response?.status,
  };
  if (result.ok !== undefined) {
    let decoded;
    try {
      decoded = fromJson(types.response, result.ok, { registry });
    } catch (e) {
      return failed(request, `the runtime's response does not read back as ${types.response.typeName}: ${e.message}`);
    }
    response.payloads = [decoded.payload ?? create(ConformancePayloadSchema)];
  } else if (result.error !== undefined) {
    response.error = {
      code: codeOf(result.error.code),
      message: result.error.message,
      details: result.error.details.map(detail),
    };
  } else {
    response.error = transportError(result.transport);
  }
  return create(ClientCompatResponseSchema, {
    testName: request.testName,
    result: { case: "response", value: response },
  });
}

// Why a request asks for something the runtime does not do, or nothing.
// conformance.yaml keeps the runner from sending such requests.
function refusal(request) {
  if (request.service !== service) return `no service ${request.service}`;
  if (!Object.hasOwn(methods, request.method ?? "")) return `no unary method ${request.method}`;
  if (request.protocol !== Protocol.CONNECT) return `protocol ${Protocol[request.protocol]} is not supported`;
  if (request.codec !== Codec.JSON) return `codec ${Codec[request.codec]} is not supported`;
  if (request.compression !== Compression.IDENTITY && request.compression !== Compression.UNSPECIFIED) {
    return `compression ${Compression[request.compression]} is not supported`;
  }
  if (request.httpVersion !== HTTPVersion.HTTP_VERSION_1) {
    return `HTTP version ${HTTPVersion[request.httpVersion]} is not supported`;
  }
  if (request.serverTlsCert.length > 0) return "TLS is not supported";
  if (request.rawRequest !== undefined) return "raw requests are not supported";
  if (request.requestMessages.length !== 1) return `a unary call takes one request, not ${request.requestMessages.length}`;
  return null;
}

// An answer's headers, split as the Connect protocol sends a unary call's
// metadata: its trailers as headers prefixed `trailer-`, its headers as the
// rest. elm/http gives one value per name, a repeated header's values joined
// with ", ", which the suite reads as the list it was.
function metadata(answer) {
  const responseHeaders = [];
  const responseTrailers = [];
  for (const [name, value] of answer?.headers ?? []) {
    const lower = name.toLowerCase();
    if (lower.startsWith("trailer-")) responseTrailers.push({ name: lower.slice("trailer-".length), value: [value] });
    else responseHeaders.push({ name: lower, value: [value] });
  }
  return { responseHeaders, responseTrailers };
}

// A Connect code name (`not_found`) as the suite's Code (CODE_NOT_FOUND).
function codeOf(name) {
  const code = Code[name.toUpperCase()];
  return code === undefined ? Code.UNKNOWN : code;
}

// An error detail as the runtime gives it (Proto.Any.encodeJson): proto3 JSON
// with "@type", or {"type", "value"} for a detail that arrived as protobuf
// binary only, whose base64 value is the Any's bytes as they came.
function detail(json) {
  if (json["@type"] === undefined && typeof json.type === "string") {
    const typeUrl = json.type.includes("/") ? json.type : `type.googleapis.com/${json.type}`;
    return create(AnySchema, { typeUrl, value: Buffer.from(json.value ?? "", "base64") });
  }
  return fromJson(AnySchema, json, { registry });
}

// The error a transport failure stands for. A timeout is the client's own
// deadline passing; anything else did not get an answer the runtime could
// read as one.
function transportError(problem) {
  if (problem === "Timeout") return { code: Code.DEADLINE_EXCEEDED, message: "Timeout" };
  if (problem === "NetworkError") return { code: Code.UNAVAILABLE, message: "NetworkError" };
  return { code: Code.UNKNOWN, message: problem };
}

function failed(request, message) {
  return create(ClientCompatResponseSchema, {
    testName: request.testName,
    result: { case: "error", value: { message } },
  });
}

// The length-prefixed messages of a stream, as they arrive.
async function* frames(stream) {
  let buffered = Buffer.alloc(0);
  for await (const chunk of stream) {
    buffered = Buffer.concat([buffered, chunk]);
    while (buffered.length >= 4) {
      const size = buffered.readUInt32BE(0);
      if (buffered.length < 4 + size) break;
      yield buffered.subarray(4, 4 + size);
      buffered = buffered.subarray(4 + size);
    }
  }
  if (buffered.length > 0) throw new Error(`stdin ended inside a message (${buffered.length} bytes left)`);
}

function write(message) {
  const bytes = toBinary(ClientCompatResponseSchema, message);
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(bytes.length);
  return new Promise((resolve, reject) =>
    process.stdout.write(Buffer.concat([prefix, bytes]), (e) => (e ? reject(e) : resolve())),
  );
}

async function main(argv) {
  let send = "halves";
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--send") send = argv[++i];
    else {
      console.error("usage: conformance.mjs [--send halves|sendTraced|send|task]");
      process.exit(2);
    }
  }
  process.on("SIGTERM", () => process.exit(1));
  const runner = await createRunner({ elm: path.join(here, "build", "elm.js") });
  // The runner makes one call at a time, so requests are answered in order.
  for await (const bytes of frames(process.stdin)) {
    const request = fromBinary(ClientCompatRequestSchema, bytes);
    let response;
    try {
      response = await answer(runner, send, request);
    } catch (e) {
      response = failed(request, `conformance.mjs: ${e.stack ?? e}`);
    }
    await write(response);
  }
  process.exit(0);
}

await main(process.argv.slice(2));
