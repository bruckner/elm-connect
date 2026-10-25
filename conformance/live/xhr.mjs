// A browser-shaped XMLHttpRequest over node:http, as much of it as elm/http
// uses: open, setRequestHeader, send (text, or a DataView or ArrayBuffer of
// bytes), abort, timeout, withCredentials, responseType "" (text) or
// "arraybuffer", the load, error, timeout, abort and progress events (and
// upload progress),
// status, statusText, response, responseText, responseURL and
// getAllResponseHeaders. HTTP only, no TLS: the live suite's servers are local.
//
// Unlike a browser it hides no response header (nothing is cross-origin here)
// and forbids no request header, and every exchange is reported to `observe`,
// so the runner can say what went over the wire.

import http from "node:http";

const UNSENT = 0;
const OPENED = 1;
const DONE = 4;

class Target {
  #listeners = new Map();

  addEventListener(type, listener) {
    if (!this.#listeners.has(type)) this.#listeners.set(type, []);
    this.#listeners.get(type).push(listener);
  }

  removeEventListener(type, listener) {
    const list = this.#listeners.get(type) ?? [];
    const at = list.indexOf(listener);
    if (at >= 0) list.splice(at, 1);
  }

  dispatch(type, init = {}) {
    const event = { type, target: this, lengthComputable: false, loaded: 0, total: 0, ...init };
    for (const listener of [...(this.#listeners.get(type) ?? [])]) listener.call(this, event);
    const handler = this["on" + type];
    if (typeof handler === "function") handler.call(this, event);
  }
}

// Make an XMLHttpRequest class whose exchanges are reported to `observe`.
export function makeXMLHttpRequest(observe = () => {}) {
  return class XMLHttpRequest extends Target {
    static UNSENT = UNSENT;
    static OPENED = OPENED;
    static DONE = DONE;

    readyState = UNSENT;
    status = 0;
    statusText = "";
    response = "";
    responseText = "";
    responseURL = "";
    responseType = "";
    timeout = 0;
    withCredentials = false;
    upload = new Target();

    #method = "GET";
    #url = null;
    #headers = [];
    #responseHeaders = [];
    #request = null;
    #exchange = null;
    #timer = null;
    #finished = false;

    open(method, url, async = true) {
      if (!async) throw new Error("synchronous requests are not supported");
      // Throws on a malformed URL, as a browser's open does.
      const parsed = new URL(url);
      if (parsed.protocol !== "http:") throw new SyntaxError("only http: is supported: " + url);
      this.#method = method.toUpperCase();
      this.#url = parsed;
      this.#headers = [];
      this.readyState = OPENED;
    }

    setRequestHeader(name, value) {
      if (this.readyState !== OPENED) throw new Error("setRequestHeader before open");
      this.#headers.push([name, String(value)]);
    }

    getAllResponseHeaders() {
      return this.#responseHeaders.map(([k, v]) => `${k.toLowerCase()}: ${v}\r\n`).join("");
    }

    getResponseHeader(name) {
      const found = this.#responseHeaders.filter(([k]) => k.toLowerCase() === name.toLowerCase());
      return found.length ? found.map(([, v]) => v).join(", ") : null;
    }

    send(body = null) {
      if (this.readyState !== OPENED) throw new Error("send before open");
      if (this.responseType !== "" && this.responseType !== "text" && this.responseType !== "arraybuffer") {
        throw new Error(`responseType ${this.responseType} is not supported`);
      }
      const binary = ArrayBuffer.isView(body)
        ? Buffer.from(body.buffer, body.byteOffset, body.byteLength)
        : body instanceof ArrayBuffer
          ? Buffer.from(body)
          : null;
      const exchange = {
        method: this.#method,
        url: this.#url.href,
        requestHeaders: this.#headers,
        body: binary !== null || body === null || body === undefined ? null : String(body),
        bodyBase64: binary === null ? undefined : binary.toString("base64"),
        timeout: this.timeout,
        withCredentials: this.withCredentials,
        status: null,
        responseHeaders: null,
        responseBody: null,
        outcome: "pending",
      };
      observe(exchange);
      this.#exchange = exchange;
      const payload = binary ?? (exchange.body === null ? null : Buffer.from(exchange.body, "utf8"));
      const headers = {};
      for (const [k, v] of this.#headers) {
        const key = k.toLowerCase();
        headers[key] = key in headers ? `${headers[key]}, ${v}` : v;
      }
      if (payload !== null) headers["content-length"] = String(payload.length);

      // A browser's timeout covers the whole exchange, not idle time on the
      // socket.
      if (this.timeout > 0) {
        this.#timer = setTimeout(() => this.#fail("timeout", exchange), this.timeout);
      }
      const request = http.request(this.#url, { method: this.#method, headers, agent: false });
      this.#request = request;
      request.on("error", () => this.#fail("error", exchange));
      request.on("response", (response) => {
        const chunks = [];
        response.on("data", (chunk) => {
          chunks.push(chunk);
          if (this.#finished) return;
          const loaded = chunks.reduce((n, c) => n + c.length, 0);
          const total = Number(response.headers["content-length"] ?? 0);
          this.dispatch("progress", { loaded, total, lengthComputable: total > 0 });
        });
        response.on("error", () => this.#fail("error", exchange));
        response.on("end", () => {
          if (this.#finished) return;
          this.#finished = true;
          clearTimeout(this.#timer);
          const raw = response.rawHeaders;
          this.#responseHeaders = [];
          for (let i = 0; i < raw.length; i += 2) this.#responseHeaders.push([raw[i], raw[i + 1]]);
          this.status = response.statusCode;
          this.statusText = response.statusMessage ?? "";
          this.responseURL = this.#url.href;
          const whole = Buffer.concat(chunks);
          if (this.responseType === "arraybuffer") {
            this.response = whole.buffer.slice(whole.byteOffset, whole.byteOffset + whole.byteLength);
            this.responseText = "";
          } else {
            this.responseText = whole.toString("utf8");
            this.response = this.responseText;
          }
          this.readyState = DONE;
          exchange.status = this.status;
          exchange.responseHeaders = Object.fromEntries(
            this.#responseHeaders.map(([k, v]) => [k.toLowerCase(), v]),
          );
          exchange.responseBody = this.responseType === "arraybuffer" ? whole.toString("base64") : this.responseText;
          exchange.outcome = "load";
          this.dispatch("load");
          this.dispatch("loadend");
        });
      });
      if (payload !== null) {
        // One upload progress event once the body is written, as a browser
        // gives for a small body.
        request.on("finish", () => {
          if (!this.#finished) {
            this.upload.dispatch("progress", { loaded: payload.length, total: payload.length, lengthComputable: true });
          }
        });
        request.write(payload);
      }
      request.end();
    }

    abort() {
      if (this.#finished || !this.#request) return;
      this.#finished = true;
      clearTimeout(this.#timer);
      this.#request.destroy();
      this.#exchange.outcome = "abort";
      this.readyState = DONE;
      this.status = 0;
      this.dispatch("abort");
      this.dispatch("loadend");
    }

    #fail(type, exchange) {
      if (this.#finished) return;
      this.#finished = true;
      clearTimeout(this.#timer);
      this.#request?.destroy();
      this.readyState = DONE;
      this.status = 0;
      exchange.outcome = type;
      this.dispatch(type);
      this.dispatch("loadend");
    }
  };
}
