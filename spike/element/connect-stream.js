// <connect-stream>: a server stream that is open while the element is in the
// document. Its `open` property is the value Rpc.Stream.open gives (set with
// Html.Attributes.property, so the request's headers never become an
// attribute), and every event the companion emits is dispatched as a
// "stream" CustomEvent with the event as `detail`, the JSON Rpc.Stream.event
// and Rpc.Stream.Session.incoming decode.
//
// The stream's identity is the command's `id`: setting `open` again with the
// same id (as every re-render does, since the view builds a new value) keeps
// the stream and only remembers the value; a new id replaces the stream; null
// cancels it. Removing the element cancels it, unless it is back in the
// document by the end of the task (a node moved within one patch).

import { createStreams } from "../../runtime/stream.js";

export const stats = { sets: 0, opens: 0, cancels: 0 };

class ConnectStream extends HTMLElement {
  #command = null;
  #live = null;
  #streams = createStreams((event) => this.dispatchEvent(new CustomEvent("stream", { detail: event })));

  set open(command) {
    stats.sets++;
    this.#command = command ?? null;
    if (this.isConnected) this.#sync();
  }

  get open() {
    return this.#command;
  }

  connectedCallback() {
    this.#sync();
  }

  disconnectedCallback() {
    queueMicrotask(() => {
      if (!this.isConnected) this.#cancel();
    });
  }

  #sync() {
    const id = this.#command?.id ?? null;
    if (id === this.#live) return;
    this.#cancel();
    if (id !== null) {
      stats.opens++;
      this.#live = id;
      this.#streams.run(this.#command);
    }
  }

  #cancel() {
    if (this.#live !== null) {
      stats.cancels++;
      this.#streams.cancel(this.#live);
      this.#live = null;
    }
  }
}

customElements.define("connect-stream", ConnectStream);
