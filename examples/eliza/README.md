# The Eliza example

The program [`docs/trying.md`](../../docs/trying.md) walks through: a
page that sends one call, `connectrpc.eliza.v1.ElizaService/Say`, to
ConnectRPC's public demo server at `https://demo.connectrpc.com`, and
shows the answer, and streams `Introduce`, a server stream, through the
JavaScript companion `runtime/stream.js`. It needs no server of your own.

```
proto/connectrpc/eliza/v1/eliza.proto   the API, as connectrpc/examples-go publishes it
generated/                              the Elm elm-connect 0.1.0 generates from it
src/Main.elm                            the page
index.html                              loads elm.js and wires the ports to the companion
elm.json                                the runtime read from this repository's src/
```

The generated modules were written from this directory with

```sh
elm-connect gen -I ../../spike/eliza-proto connectrpc/eliza/v1/eliza.proto --streaming server --out generated
```

from a copy of the proto without `Converse`, the bidirectional method,
which `--streaming server` refuses. To build and open the page:

```sh
elm make src/Main.elm --output=elm.js
python3 -m http.server 8000 -d ../..    # then http://127.0.0.1:8000/examples/eliza/
```

`just elm-check` compiles it with the runtime in this repository.
