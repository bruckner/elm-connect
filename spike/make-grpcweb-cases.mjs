// Write conformance/live/cases/grpcweb.json: the notes server over
// gRPC-Web, run against the codec=both build. The calls are proto.json's
// Connect calls, sent over Rpc.Transport.grpcWeb and expected to give the
// same results (an error's code, message and details), less what only the
// Connect protocol shows (its headers, its JSON error bodies, GET); plus
// gRPC-Web's own: its content type, grpc-timeout and X-Grpc-Web on the wire.
import { readFileSync, writeFileSync } from 'node:fs';

const proto = JSON.parse(readFileSync('conformance/live/cases/proto.json', 'utf8'));
const svc = 'notes.v1.NotesService';
const connectOnly = (name) => /useGet|transcode|maxGetUrl/.test(name);
// The detail Anys as protobuf binary, as `detailsBinary` reports them for
// these cases over Connect with the proto codec.
const detailsBinary = {
  'proto NOT_FOUND with ErrorInfo': ['Cih0eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5ycGMuRXJyb3JJbmZvEj0KDk5PVEVfTk9UX0ZPVU5EEhFub3Rlcy5leGFtcGxlLmNvbRoYCgRuYW1lEhBub3Rlcy9mcm9tLXByb3Rv'],
  'proto INVALID_ARGUMENT with BadRequest': ['Cil0eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5ycGMuQmFkUmVxdWVzdBIfCh0KBXRpdGxlEhRhIG5vdGUgbmVlZHMgYSB0aXRsZQ=='],
};

const cases = proto
  .filter((c) => !connectOnly(c.name))
  .map((c) => {
    const config = { ...c.call.config };
    delete config.codec;
    const result = structuredClone(c.expect.result);
    if (result.error) {
      // The status is the same; where it was read from and the answer it
      // came in are the protocol's own. connect-go answers a unary error
      // over gRPC-Web trailers-only, the status in the headers. A Connect
      // detail with `debug` holds its JSON beside its binary and gRPC-Web's
      // its binary alone, so details compare as the binary the Any writes,
      // which is what the Connect run gives too.
      if (result.error.source === 'ConnectBody') result.error.source = 'GrpcHeaders';
      delete result.error.response;
      if (result.error.details) {
        result.error.detailsBinary = detailsBinary[c.name];
        delete result.error.details;
      }
    }
    return {
      name: c.name.replace(/^proto /, 'grpc-web '),
      ...(c.note ? { note: `Over Connect: ${c.note}` } : {}),
      call: { ...c.call, transport: 'grpcweb', config },
      expect: { result },
    };
  });

const grpcWebWire = {
  requestHeaders: { $contains: [['Content-Type', 'application/grpc-web+proto'], ['X-Grpc-Web', '1'], ['grpc-timeout', '5000m']] },
  responseHeaders: { 'content-type': 'application/grpc-web+proto' },
  status: 200,
};
cases.push(
  {
    name: 'grpc-web headers and grpc-timeout',
    call: { service: svc, method: 'GetNote', transport: 'grpcweb', request: { name: 'notes/welcome' }, config: { timeout: 5000 } },
    expect: {
      result: { ok: { name: 'notes/welcome' } },
      trace: { httpStatus: 200, code: 'ok', transport: 'grpc-web', request: { method: 'POST', headers: [['X-Grpc-Web', '1'], ['grpc-timeout', '5000m']], body: null } },
      wire: [grpcWebWire],
    },
  },
  {
    name: 'grpc-web timeout',
    call: { service: svc, method: 'GetNote', transport: 'grpcweb', request: { name: 'notes/slow' }, config: { timeout: 500 } },
    expect: { result: { noAnswer: 'Timeout' }, trace: { code: 'deadline_exceeded', request: { timeout: 500, headers: [['X-Grpc-Web', '1'], ['grpc-timeout', '500m']] } }, wire: [{ timeout: 500, outcome: 'timeout' }] },
  },
);
writeFileSync('conformance/live/cases/grpcweb.json', JSON.stringify(cases, null, 2) + '\n');
console.log(`${cases.length} cases`);
