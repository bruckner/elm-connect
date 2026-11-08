module Live.Codec exposing (empty, entry, registry)

{-| The dispatch tables' entries, for the build against bindings generated
with `codec=both`: a service has a `.Json` and a `.Proto` calls module, so an
entry has a JSON call and a protobuf binary one, and sends an envelope in the
codec it names. The build against `codec=json` has its own module of this
name (`json/Live/Codec.elm`), and its own tables.
-}

import Connectrpc.Conformance.V1
import Json.Decode exposing (Decoder)
import Json.Encode
import Live.Call exposing (Entry)
import Notes.V1
import Proto.Any
import Proto.Bytes
import Proto.ErrorDetails
import Proto.Message exposing (Message)
import Proto.Registry exposing (Registry)
import Proto.WellKnown
import Routes.V1
import Rpc


{-| The entry for a method, from its generated JSON and binary call
functions, its request's decoder and its response's typed value: the response is written as its
protobuf binary, and as the proto3 JSON the build's registries convert that
to.
-}
entry : (req -> Rpc.Call Rpc.Json req res) -> (req -> Rpc.Call Rpc.Proto req res) -> Decoder req -> Message res -> Entry msg
entry toJsonCall toProtoCall decoder message =
    Live.Call.entryWith { json = Just toJsonCall, proto = Just toProtoCall }
        decoder
        { response =
            \response ->
                let
                    packed =
                        Proto.Any.pack message response
                in
                [ ( "ok"
                  , Proto.Any.toJson registry packed
                        |> Result.withDefault Json.Encode.null
                  )
                , ( "okBinary", Json.Encode.string (Proto.Bytes.toBase64 (Proto.Any.bytes packed)) )
                ]
        , detail = Live.Call.detailWith (Proto.Registry.union Proto.ErrorDetails.registry registry)
        }



-- region registry


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



-- endregion registry


{-| `google.protobuf.Empty`'s typed value in this build's world.
-}
empty : Message ()
empty =
    Proto.WellKnown.empty
