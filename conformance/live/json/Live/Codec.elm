module Live.Codec exposing (empty, entry, registry)

{-| The dispatch tables' entries, for the build against bindings generated
with `codec=json`: a service has its `.Json` calls module alone, so an entry
has the JSON call function alone, and an envelope naming the proto codec is
refused. The build against `codec=both` has its own module of this name
(`both/src/Live/Codec.elm`), and its own tables.
-}

import Connectrpc.Conformance.V1
import Json.Decode exposing (Decoder)
import Json.Encode
import Live.Call exposing (Entry)
import Notes.V1
import Proto.Any
import Proto.ErrorDetails
import Proto.Message exposing (Message)
import Proto.Registry exposing (Registry)
import Proto.WellKnown
import Routes.V1
import Rpc


{-| The entry for a method, from its generated JSON call function, its
request's decoder and its response's typed value: the response is written as
the proto3 JSON the build's registries convert its binary to.
-}
entry : (req -> Rpc.Call Rpc.Json req res) -> Decoder req -> Message res -> Entry msg
entry toCall decoder message =
    Live.Call.entryWith { json = Just toCall, proto = Nothing }
        decoder
        { response =
            \response ->
                [ ( "ok"
                  , Proto.Any.toJson registry (Proto.Any.pack message response)
                        |> Result.withDefault Json.Encode.null
                  )
                ]
        , detail = Live.Call.detailWith (Proto.Registry.union Proto.ErrorDetails.registry registry)
        }


{-| Every type the build's packages hold, and the well-known types: what an
application calling these services gives its client, and the runner's
`"registry": "build"`. It holds no `google.rpc` error detail.
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
