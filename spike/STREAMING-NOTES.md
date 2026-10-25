# Server streaming: protocol notes

Facts the spike's core and Elm side rely on, each with its source, checked
2026-10-24. "Plan" means the spike plan's "Protocol facts" list; where a fact
here corrects it, the entry says **Correction**.

## Connect (https://connectrpc.com/docs/protocol/)

Section "Streaming RPCs" (Streaming-Request, Streaming-Response, Envelope,
EndStreamResponse):

- **Method and path.** POST only, to `/<routing prefix>/<Procedure-Name>`,
  case-sensitive. Unary-Get-Request is defined for unary RPCs alone, so a
  streaming method is never a GET. (Plan: correct.)
- **Content type.** `application/connect+json` or `application/connect+proto`
  (`application/connect+<codec>`). A server SHOULD answer a request whose type
  does not begin `application/connect+` with HTTP 415. The response carries the
  same `application/connect+<codec>` type. (Plan: correct.)
- **Connect-Protocol-Version.** **Correction (minor):** the streaming request
  grammar lists it as optional; only the unary section says clients "should"
  send it, and connect-go's `WithRequireConnectProtocolHeader` applies to unary
  only. Sending `Connect-Protocol-Version: 1` is harmless and kept for symmetry
  with `Rpc.request`, but a server cannot rely on it for streams.
- **Request body.** One enveloped message for a server-streaming call; there is
  no unenveloped form. (Plan: correct.)
- **Envelope.** 1 byte of flags, 4-byte big-endian unsigned length, then the
  message. Flag `0x01` (least significant bit): the message is compressed with
  the stream's `Connect-Content-Encoding`; it MUST be 0 when that encoding is
  absent or `identity`. Flag `0x02`: the message is the EndStreamResponse, set
  on the final response message only and never on a request message. The six
  high bits are reserved. (Plan: correct.)
- **Compression headers.** **Correction (naming):** a stream negotiates with
  `Connect-Content-Encoding` (what this message stream uses) and
  `Connect-Accept-Encoding` (what the peer accepts), not `Content-Encoding` /
  `Accept-Encoding`, which unary uses. A client that sends no
  `Connect-Accept-Encoding` should get identity, but a server MAY still compress
  with an encoding it believes the client supports only if the client said so;
  the core refuses flag 0x01 with a clear error rather than decompress.
- **Timeout.** `Connect-Timeout-Ms`, optional, at most 10 digits, applies to the
  whole call, so for a stream to the whole stream including idle time between
  messages. (Plan: correct.) A server-side deadline arrives as an
  EndStreamResponse with code `deadline_exceeded`; the client's own timer must
  abort the fetch too, since a stuck proxy may never send it.
- **HTTP status.** "Streaming responses always have an HTTP status of 200 OK."
  An RPC error, even one before any message, is an EndStreamResponse inside a
  200. **Addition:** a non-200 can still arrive from something that is not the
  Connect server (a proxy's 502/503, a router's 404, a 415 for a wrong content
  type). connect-es reads such an answer as an error with the code
  `Rpc.Code.fromHttpStatus` gives; the core reports `end` with that code and
  the body's text as message (it tries the Connect unary error JSON first).
- **EndStreamResponse.** JSON `{"error": {...}?, "metadata": {...}?}`. `error` is
  the unary Error object (`code` string, optional `message`, optional `details`
  as `{"type","value","debug"?}`), present on failure and absent on success; a
  successful stream may end with `{}`. `metadata` maps header names to
  **arrays** of strings (the trailers). (Plan: correct; the arrays are worth
  noting since unary trailers are `trailer-` prefixed headers.)
- **End-stream is mandatory.** The server MUST send an EndStreamResponse as the
  last message. **Addition:** a body that ends without one is therefore a
  transport failure, not a clean end; connect-es raises
  `missing EndStreamResponse` (code `unknown`/internal). The core reports it as
  `error` with reason `"missing end-stream"`, mapped to `NoAnswer NetworkError`
  in Elm so the session reconnects.

## grpc-gateway (https://github.com/grpc-ecosystem/grpc-gateway, `runtime/handler.go`, `ForwardResponseStream`)

grpc-gateway's docs say little; the source is the reference
(https://github.com/grpc-ecosystem/grpc-gateway/blob/main/runtime/handler.go).

- Each message is marshalled as `{"result": <message>}` followed by the
  marshaler's delimiter, `"\n"` by default: newline-delimited JSON.
  (Plan: correct.)
- An error is `{"error": <google.rpc.Status as proto3 JSON>}` plus the
  delimiter: integer `code`, `message`, `details` as `Any` JSON (`@type`).
  **Correction (missing case):** if the error comes before the first message
  (`wroteHeader` false), the gateway sets the HTTP status from the code
  (`HTTPStatusFromCode`, e.g. 404 for `NOT_FOUND`) and the body is the same
  `{"error": …}` chunk, not a bare `google.rpc.Status` as a unary error is. The
  core must therefore read a non-200 NDJSON body as one error chunk.
- A clean end is EOF with no marker: there is no end-of-stream object, so a
  dropped connection after the last message cannot be told from a clean end.
- Content type: the marshaler's `StreamContentType` if it has one, else its
  `ContentType` (`application/json` for the default JSONPb marshaler).

## Envoy gRPC-JSON transcoder (https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/grpc_json_transcoder/v3/transcoder.proto)

Docs: `print_options.stream_newline_delimited` "return all streams as
newline-delimited JSON messages instead of as a comma-separated array";
`stream_sse_style_delimited` "enforces Server-Sent Events (SSE) message framing"
and makes `stream_newline_delimited` ignored. Source for the details:
`source/extensions/filters/http/grpc_json_transcoder/json_transcoder_filter.cc`
and grpc-httpjson-transcoding `src/response_to_json_translator.cc`.

- **Array (default).** `[` before the first message, `,` between messages, `]`
  at the end, `[]` for an empty stream; `Content-Type: application/json`. The
  messages are bare proto3 JSON (no `result` wrapper). (Plan: correct.)
- **NDJSON.** Bare messages each followed by `\n`. (Plan: correct.)
- **SSE.** `data: <message JSON>\n\n` per message,
  `Content-Type: text/event-stream`. No `event:`/`id:` fields. (Plan: correct.)
- **Errors. Correction (important):** there is no in-band error frame in any of
  the three framings. An error before any message is a trailers-only gRPC
  response, which Envoy turns into an HTTP status (`grpcToHttpStatus`) and, with
  `convert_grpc_status: true`, a `google.rpc.Status` JSON body. An error after
  the first message (`has_body_`) is not converted: the 200 body is closed (the
  array gets its `]`) and `grpc-status`/`grpc-message` travel as HTTP trailers,
  removed on HTTP/1 connections and in any case unreadable by `fetch`. **A
  browser cannot tell a mid-stream error from a clean end over Envoy.** The core
  reports `end` with no error; the report lists it as a limit, and the session's
  resume-and-reconnect policy is what recovers.

## gRPC-Web (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md)

`application/grpc-web+proto` (or `+json`), the same 5-byte envelope, trailers
in-band as a frame with flag `0x80` holding HTTP/1-style header lines;
`application/grpc-web-text` is base64 of that body. (Plan: correct; out of
scope.)

## Browser (https://developer.mozilla.org/en-US/docs/Web/API/Streams_API)

- `fetch` resolves at the response headers; `response.body.getReader()` yields
  `Uint8Array` chunks of arbitrary size, split anywhere, including inside a
  frame header or a UTF-8 sequence. `TextDecoder.decode(chunk, {stream: true})`
  holds a partial sequence until the next chunk.
- `AbortController.abort()` rejects the pending `fetch` or `read()` with an
  `AbortError` DOMException and closes the connection.
- Response-body streaming works in current Chrome, Firefox and Safari; request
  bodies are sent whole (one message), so no `duplex: "half"` is needed.
- Response headers are readable only if CORS exposes them
  (`Access-Control-Expose-Headers`); trailers are never readable.
