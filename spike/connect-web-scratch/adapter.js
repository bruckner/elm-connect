// The same event surface as runtime/stream.js, over connect-web. No generated
// schemas: each method is described at run time with google.protobuf.Value as
// its input and output, so any JSON passes through fromJson/toJson unchanged.
import { createConnectTransport } from "@connectrpc/connect-web";
import { ConnectError } from "@connectrpc/connect";
import { ValueSchema } from "@bufbuild/protobuf/wkt";
import { fromJson, toJson } from "@bufbuild/protobuf";

function rawMethod(service, name) {
  const parent = { kind: "service", typeName: service, name: service.split(".").pop(), methods: [], method: {} };
  return { kind: "rpc", name, localName: name, parent, methodKind: "server_streaming", input: ValueSchema, output: ValueSchema, idempotency: 0 };
}

export function createStreams(emit, { baseUrl, fetch: fetchImpl } = {}) {
  const live = new Map();
  const transports = new Map();
  const transportFor = (url) => {
    if (!transports.has(url)) transports.set(url, createConnectTransport({ baseUrl: url, fetch: fetchImpl }));
    return transports.get(url);
  };
  async function open(id, { service, method, headers = [], body, timeoutMs, baseUrl: url = baseUrl }) {
    cancel(id);
    const controller = new AbortController();
    live.set(id, controller);
    const send = (e) => live.get(id) === controller && emit({ id, ...e });
    try {
      const res = await transportFor(url).stream(rawMethod(service, method), controller.signal, timeoutMs, headers, (async function* () {
        yield fromJson(ValueSchema, JSON.parse(body));
      })(), undefined);
      const h = {};
      res.header.forEach((v, k) => (h[k] = v));
      send({ kind: "headers", status: 200, headers: h });
      for await (const m of res.message) send({ kind: "message", json: JSON.stringify(toJson(ValueSchema, m)) });
      const t = {};
      res.trailer.forEach((v, k) => (t[k] = [v]));
      send({ kind: "end", status: 200, error: null, metadata: t });
    } catch (e) {
      const err = ConnectError.from(e);
      if (controller.signal.aborted && live.get(id) !== controller) return;
      send({ kind: "end", status: 200, error: { code: err.code, message: err.rawMessage, details: err.details }, metadata: {} });
    } finally {
      if (live.get(id) === controller) live.delete(id);
    }
  }
  function cancel(id) {
    live.get(id)?.abort();
    live.delete(id);
  }
  return { open, cancel };
}
