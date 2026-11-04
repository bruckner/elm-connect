module Live.Codec exposing (clientRegistry, empty, entry)

{-| The dispatch tables' entries, for the build against bindings generated
with `codec=json`: a generated call is `Rpc.Call Rpc.Json`, so an entry has
the JSON call function alone, and an envelope naming the proto codec is
refused. The build against `codec=both` has its own module of this name
(`both/src/Live/Codec.elm`).
-}

import Connectrpc.Conformance.V1
import Google.Rpc
import Json.Decode exposing (Decoder)
import Json.Encode
import Live.Call exposing (Entry)
import Notes.V1
import Proto.Any
import Proto.Message exposing (Message)
import Proto.Registry exposing (Registry)
import Proto.WellKnown
import Routes.V1
import Rpc


{-| The entry for a method, from its generated call function, given twice so
that the tables read the same in both builds, its request's decoder and its
response's typed value: the response is written as the proto3 JSON the
build's registries convert its binary to.
-}
entry : (req -> Rpc.Call Rpc.Json req res) -> (req -> Rpc.Call Rpc.Json req res) -> Decoder req -> Message res -> Entry msg
entry toCall _ decoder message =
    Live.Call.entryWith { json = Just toCall, proto = Nothing }
        decoder
        { response =
            \response ->
                [ ( "ok"
                  , Proto.Any.toJson registry (Proto.Any.pack message response)
                        |> Maybe.withDefault Json.Encode.null
                  )
                ]
        , detail = Live.Call.detailWith (Proto.Registry.union Google.Rpc.registry registry)
        }


{-| The registry every client the runner builds converts through: every
type the build's packages hold, lenient, so that an error detail of a type
none holds, such as a google.rpc one, is kept as its JSON.
-}
clientRegistry : Registry
clientRegistry =
    Proto.Registry.lenient registry


{-| Every type the build's packages hold.
-}
registry : Registry
registry =
    Proto.Registry.unionAll
        [ Notes.V1.registry
        , Routes.V1.registry
        , Connectrpc.Conformance.V1.registry
        , Proto.Registry.wellKnown
        ]


{-| `google.protobuf.Empty`'s typed value.
-}
empty : Message ()
empty =
    Proto.WellKnown.empty
