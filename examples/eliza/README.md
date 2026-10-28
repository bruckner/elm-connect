# The Eliza example

The program [`docs/trying.md`](../../docs/trying.md) walks through: a
page that sends one call, `connectrpc.eliza.v1.ElizaService/Say`, to
ConnectRPC's public demo server at `https://demo.connectrpc.com`, and
shows the answer. It needs no server of your own.

```
proto/connectrpc/eliza/v1/eliza.proto   the API, as connectrpc/examples-go publishes it
generated/                              the Elm elm-connect 0.2.0 generates from it
src/Main.elm                            the page
elm.json                                the runtime read from this repository's src/
```

The generated modules were written from this directory with

```sh
elm-connect gen -I proto connectrpc/eliza/v1/eliza.proto --streaming skip --out generated
```

which leaves out the service's two streaming methods. In this repository, `just eliza-gen` runs it with the CLI built from the checkout. To build and open
the page:

```sh
elm make src/Main.elm --output=index.html
open index.html    # or xdg-open, or open it from the browser
```

`just elm-check` compiles it with the runtime in this repository.
