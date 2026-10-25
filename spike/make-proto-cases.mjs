// Write conformance/live/cases/proto.json (the notes server over
// application/proto, run against the codec=both build) and
// proto-missing.json (the same calls refused by the JSON-only build).
import { writeFileSync } from 'node:fs';

const svc = 'notes.v1.NotesService';
const proto = (extra = {}) => ({ codec: 'proto', ...extra });
const call = (method, request, config = {}, more = {}) => ({ service: svc, method, transport: 'connect', request, config: proto(config), ...more });
const protoWire = { requestHeaders: { $contains: [['Content-Type', 'application/proto']] }, responseHeaders: { 'content-type': 'application/proto' } };
const attachment = { type: 'google.protobuf.Timestamp', value: 'CKXr3MoG' };

const cases = [
  {
    name: 'proto GetNote',
    note: 'The answer is read from protobuf binary; an Any read from binary holds its bytes and writes the Connect detail form.',
    call: call('GetNote', { name: 'notes/welcome' }),
    expect: {
      result: { ok: { name: 'notes/welcome', title: 'Welcome', tags: ['intro', 'example'], visibility: 'VISIBILITY_PUBLIC', createTime: '2026-01-01T00:00:00Z', ttl: '90s', metadata: { lang: 'en' }, extra: { owner: 'ada', pinned: true, stars: 3 }, link: 'https://example.com/welcome', attachment, revision: '9007199254740993' } },
      trace: { httpStatus: 200, code: 'ok', headers: { 'content-type': 'application/proto' }, request: { method: 'POST', headers: [['Connect-Protocol-Version', '1']], body: null, bodyBase64: 'Cg1ub3Rlcy93ZWxjb21l' } },
      wire: [protoWire],
    },
  },
  {
    name: 'proto ListNotes',
    call: call('ListNotes', { pageSize: 10, filter: 'Welcome', visibility: 'VISIBILITY_PUBLIC' }),
    expect: { result: { ok: { notes: [{ name: 'notes/welcome', attachment }] } }, wire: [protoWire] },
  },
  {
    name: 'proto CreateNote',
    note: 'The request Any holds a Timestamp read from JSON; the binary encoder converts it, so the server stores its value.',
    call: call('CreateNote', { note: { name: 'notes/from-proto', title: 'Created', body: 'First draft', tags: ['a', 'b'], visibility: 'VISIBILITY_PUBLIC', ttl: '3.5s', metadata: { k: 'v' }, extra: { n: 1, list: [true, null, 'x'] }, text: 'hello', attachment: { '@type': 'type.googleapis.com/google.protobuf.Timestamp', value: '2026-01-02T03:04:05Z' } } }),
    expect: { result: { ok: { name: 'notes/from-proto', title: 'Created', body: 'First draft', tags: ['a', 'b'], visibility: 'VISIBILITY_PUBLIC', ttl: '3.500s', metadata: { k: 'v' }, extra: { n: 1, list: [true, null, 'x'] }, text: 'hello', attachment } }, wire: [protoWire] },
  },
  {
    name: 'proto UpdateNote',
    call: call('UpdateNote', { note: { name: 'notes/from-proto', body: 'Second draft' }, updateMask: 'body' }),
    expect: { result: { ok: { name: 'notes/from-proto', title: 'Created', body: 'Second draft', revision: '1' } } },
  },
  {
    name: 'proto ArchiveNote',
    call: call('ArchiveNote', { name: 'notes/from-proto' }),
    expect: { result: { ok: { name: 'notes/from-proto', visibility: 'VISIBILITY_PRIVATE', tags: ['a', 'b', 'archived'], revision: '2' } } },
  },
  {
    name: 'proto DeleteNote',
    call: call('DeleteNote', { name: 'notes/from-proto' }),
    expect: { result: { ok: {} }, trace: { httpStatus: 200, code: 'ok', headers: { 'content-type': 'application/proto' } } },
  },
  {
    name: 'proto NOT_FOUND with ErrorInfo',
    note: 'An error answer stays JSON under the proto codec, and reads as the same Rpc.Error.',
    call: call('GetNote', { name: 'notes/from-proto' }),
    expect: {
      result: { error: { code: 'not_found', message: 'notes/from-proto does not exist', source: 'ConnectBody', details: [{ '@type': 'type.googleapis.com/google.rpc.ErrorInfo', reason: 'NOTE_NOT_FOUND', domain: 'notes.example.com', metadata: { name: 'notes/from-proto' } }], response: { statusCode: 404, body: { $json: { code: 'not_found' } } } } },
      trace: { httpStatus: 404, code: 'not_found', headers: { 'content-type': 'application/json' } },
    },
  },
  {
    name: 'proto INVALID_ARGUMENT with BadRequest',
    call: call('CreateNote', { note: { body: 'untitled' } }),
    expect: { result: { error: { code: 'invalid_argument', message: 'a note needs a title', source: 'ConnectBody', details: [{ '@type': 'type.googleapis.com/google.rpc.BadRequest', fieldViolations: [{ field: 'title', description: 'a note needs a title' }] }] } } },
  },
  {
    name: 'proto Ping',
    note: 'google.protobuf.Empty both ways: an empty body.',
    call: call('Ping', {}),
    expect: { result: { ok: {} }, trace: { request: { method: 'POST', body: null, bodyBase64: '' } }, wire: [{ status: 200, responseHeaders: { 'content-type': 'application/proto', 'content-length': '0' } }] },
  },
  {
    name: 'proto useGet GetNote',
    call: call('GetNote', { name: 'notes/welcome' }, { useGet: true }),
    expect: { result: { ok: { name: 'notes/welcome', attachment } }, trace: { httpStatus: 200, request: { method: 'GET', url: { $match: '/notes\\.v1\\.NotesService/GetNote\\?connect=v1&base64=1&encoding=proto&message=Cg1ub3Rlcy93ZWxjb21l$' }, headers: [], body: null } }, wire: [{ method: 'GET', responseHeaders: { 'content-type': 'application/proto' } }] },
  },
  {
    name: 'proto useGet Ping',
    call: call('Ping', {}, { useGet: true }),
    expect: { result: { ok: {} }, trace: { request: { method: 'GET', url: { $match: '/Ping\\?connect=v1&base64=1&encoding=proto&message=$' } } } },
  },
  {
    name: 'proto useGet POSTs past maxGetUrl',
    call: call('GetNote', { name: 'notes/welcome' }, { useGet: true, maxGetUrl: 40 }),
    expect: { result: { ok: { name: 'notes/welcome' } }, trace: { request: { method: 'POST', bodyBase64: 'Cg1ub3Rlcy93ZWxjb21l' } } },
  },
  {
    name: 'proto readMaxBytes counts the binary',
    call: call('GetNote', { name: 'notes/welcome' }, { readMaxBytes: 100 }),
    expect: { result: { noAnswer: 'ResponseTooLarge 257 100' }, trace: { httpStatus: 200, code: 'resource_exhausted' } },
  },
  {
    name: 'proto writeMaxBytes counts the binary',
    note: 'The request is 15 bytes of binary where its JSON is 24.',
    call: call('GetNote', { name: 'notes/welcome' }, { writeMaxBytes: 14 }),
    expect: { result: { noAnswer: 'RequestTooLarge 15 14' }, trace: { attempts: 0 }, wire: [] },
  },
  {
    name: 'proto writeMaxBytes at the binary size sends',
    call: call('GetNote', { name: 'notes/welcome' }, { writeMaxBytes: 15 }),
    expect: { result: { ok: { name: 'notes/welcome' } } },
  },
  {
    name: 'proto halves',
    note: 'Rpc.request, elm/http with expectBytesResponse, Rpc.responseBytes.',
    call: call('GetNote', { name: 'notes/welcome' }, {}, { send: 'halves' }),
    expect: { result: { ok: { name: 'notes/welcome', attachment } }, response: { status: 200 }, wire: [protoWire] },
  },
  {
    name: 'proto halves error',
    call: call('GetNote', { name: 'notes/missing' }, {}, { send: 'halves' }),
    expect: { result: { error: { code: 'not_found', source: 'ConnectBody' } }, response: { status: 404 } },
  },
  {
    name: 'proto Rpc.send',
    call: call('GetNote', { name: 'notes/welcome' }, {}, { send: 'send' }),
    expect: { result: { ok: { name: 'notes/welcome' } }, wire: [protoWire] },
  },
  {
    name: 'proto Rpc.task',
    call: call('GetNote', { name: 'notes/missing' }, {}, { send: 'task' }),
    expect: { result: { error: { code: 'not_found', message: 'notes/missing does not exist', source: 'ConnectBody' } } },
  },
  {
    name: 'proto Rpc.taskFromRequest sends the request rewritten',
    call: call('GetNote', { name: 'notes/welcome' }, { headers: [['Authorization', 'Bearer stale']] }, { send: 'taskFromRequest', rewrite: [['authorization', 'Bearer fresh']] }),
    expect: { result: { ok: { name: 'notes/welcome' } }, wire: [{ requestHeaders: [['Authorization', 'Bearer fresh'], ['Connect-Protocol-Version', '1'], ['Content-Type', 'application/proto']], status: 200 }] },
  },
  {
    name: 'proto retry',
    call: call('GetNote', { name: 'notes/flaky' }, { retry: { attempts: 2, backoff: 10, codes: ['unavailable'], idempotentOnly: false } }),
    expect: { result: { ok: { name: 'notes/flaky' } }, trace: { attempts: 2 }, wire: [{ status: 503 }, { status: 200 }] },
  },
  {
    name: 'proto answer without an error body',
    call: call('Ping', {}, { baseUrl: '{server}/status/404' }),
    expect: { result: { error: { code: 'unimplemented', source: 'HttpStatus' } }, trace: { httpStatus: 404 } },
  },
  {
    name: 'proto grpc-status headers',
    call: call('Ping', {}, { baseUrl: '{server}/grpc-status/8' }),
    expect: { result: { error: { code: 'resource_exhausted', message: 'no backend; code 8', source: 'GrpcHeaders' } } },
  },
  {
    name: 'transcode ignores the proto codec',
    call: { service: svc, method: 'GetNote', transport: 'transcode', request: { name: 'notes/welcome' }, config: proto() },
    expect: { result: { ok: { name: 'notes/welcome', attachment: { '@type': 'type.googleapis.com/google.protobuf.Timestamp', value: '2026-01-02T03:04:05Z' } } }, trace: { transport: 'transcode', request: { method: 'GET', body: null } }, wire: [{ responseHeaders: { 'content-type': { $match: '^application/json' } } }] },
  },
  {
    name: 'transcode ignores the proto codec over the implicit route',
    call: { service: svc, method: 'Ping', transport: 'transcode', request: {}, config: proto() },
    expect: { result: { ok: {} }, trace: { request: { method: 'POST', body: '{}' } } },
  },
];

const missing = [
  {
    name: 'proto refuses a method without binary codecs, unsent',
    call: call('GetNote', { name: 'notes/welcome' }, { retry: { attempts: 3, codes: ['internal'], idempotentOnly: false } }),
    expect: { result: { noAnswer: 'MissingCodec notes.v1.NotesService/GetNote proto' }, trace: { attempts: 0, code: 'internal' }, wire: [] },
  },
  {
    name: 'proto Rpc.send refuses it too',
    call: call('Ping', {}, {}, { send: 'send' }),
    expect: { result: { noAnswer: 'MissingCodec notes.v1.NotesService/Ping proto' }, wire: [] },
  },
];

writeFileSync('conformance/live/cases/proto.json', JSON.stringify(cases, null, 2) + '\n');
writeFileSync('conformance/live/cases/proto-missing.json', JSON.stringify(missing, null, 2) + '\n');
