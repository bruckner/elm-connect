module RouteShapesTest exposing (suite)

{-| Every binding shape whose route function was once left to the
interpreter (the corpus case `routes_typed_shapes`, written under
`tests/Generated/Shapes` by `crates/elm-connect-gen/tests/routes.rs` at test
time): each method's typed routes against the interpreter over the same
bindings as data (`Proto.Method.withBindings`), through `Rpc.request` over
transcoding, for every binding and a spread of requests. The two agree but
where the typed route is deliberately different, which the last tests pin.
-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Dict
import Expect
import Generated.Shapes.Blobs.V1 as B
import Generated.Shapes.Blobs.V1.BlobService as Service
import Octets exposing (bytesOf)
import Proto.Any
import Proto.Binary
import Proto.Error
import Proto.Method
import Proto.Timestamp
import Proto.Value
import Requests exposing (builtOf, refusalOf)
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Client
import Rpc.Error
import Rpc.Protocol
import Test exposing (Test, describe, test)
import Time


base : Rpc.Client Rpc.Json
base =
    Rpc.client Rpc.Protocol.transcode "https://api.example.com/x"


withTypes : Rpc.Client Rpc.Json
withTypes =
    Rpc.Client.withRegistry B.registry base


show : Rpc.Client Rpc.Json -> Rpc.Call Rpc.Json req res -> String
show client call =
    let
        request =
            builtOf client call
    in
    request.method ++ " " ++ request.url ++ " " ++ Maybe.withDefault "<none>" (Rpc.Body.toText request.body)


{-| The call over the method's bindings as data, as generated code wrote
for these methods before every binding was typed.
-}
interpreted : Proto.Method.Descriptor -> Rpc.Call Rpc.Json req res -> Rpc.Call Rpc.Json req res
interpreted descriptor typed =
    Rpc.call (Proto.Method.withBindings (Proto.Method.bindings descriptor) (Rpc.Call.method typed)) (Rpc.Call.requestMessage typed)


{-| The typed and the interpreted request of each request over each binding,
side by side.
-}
both : Rpc.Client Rpc.Json -> Proto.Method.Descriptor -> (req -> Rpc.Call Rpc.Json req res) -> req -> List ( String, String )
both client descriptor toCall request =
    let
        typed =
            toCall request
    in
    List.range 0 (List.length (Proto.Method.bindings descriptor) - 1)
        |> List.map
            (\index ->
                case ( Rpc.Call.viaBinding index typed, Rpc.Call.viaBinding index (interpreted descriptor typed) ) of
                    ( Just t, Just i ) ->
                        ( show client t, show client i )

                    _ ->
                        ( "binding " ++ String.fromInt index, "missing" )
            )


agree : String -> Proto.Method.Descriptor -> (req -> Rpc.Call Rpc.Json req res) -> List req -> Test
agree label descriptor toCall requests =
    test label <|
        \_ ->
            let
                pairs =
                    List.concatMap (both withTypes descriptor toCall) requests
            in
            List.map Tuple.first pairs
                |> Expect.equalLists (List.map Tuple.second pairs)


{-| Bytes whose base64 holds neither `+` nor `/`, which the two write alike;
the alphabets part below.
-}
someBytes : List Bytes
someBytes =
    List.map bytesOf [ [], [ 0 ], [ 104, 105 ], [ 1, 2, 3 ], [ 0x10, 0x20, 0x30, 0x40 ] ]


blobs : List B.Blob
blobs =
    List.concatMap
        (\digest ->
            [ { digest = digest, name = "shelves/a/blobs/b", salt = bytesOf [ 1, 2, 3 ] }
            , { digest = digest, name = "", salt = bytesOf [] }
            , { digest = digest, name = "blobs/x y", salt = bytesOf [ 0x10 ] }
            ]
        )
        someBytes


packed : Proto.Any.Any
packed =
    Proto.Any.pack B.messageBlob { digest = bytesOf [ 9, 9 ], name = "n", salt = bytesOf [] }


labeleds : List B.Labeled
labeleds =
    [ { name = "tags/1", label = Nothing }
    , { name = "tags/2", label = Just packed }
    , { name = "", label = Just packed }
    , { name = "labels/a/b", label = Nothing }
    ]


labelRequests : List B.LabelBlobRequest
labelRequests =
    { labeled = Nothing, shelf = "shelves/s" }
        :: List.concatMap
            (\labeled ->
                [ { labeled = Just labeled, shelf = "shelves/s" }
                , { labeled = Just { labeled | name = "labels/" ++ labeled.name }, shelf = "" }
                ]
            )
            labeleds


folders : List B.Folder
folders =
    [ { name = "folders/1", parent = Nothing }
    , { name = "folders/2", parent = Just (B.Folder_ { name = "folders/p", parent = Nothing }) }
    , { name = "", parent = Just (B.Folder_ { name = "", parent = Just (B.Folder_ { name = "folders/g", parent = Nothing }) }) }
    , { name = "x/y", parent = Just (B.Folder_ { name = "folders/a/b", parent = Nothing }) }
    ]


moments : List B.Moment
moments =
    [ { name = "moments/1", at = Nothing }
    , { name = "moments/2", at = Proto.Timestamp.fromSecondsAndNanos 1700000000 500000000 }
    , { name = "moments/3", at = Proto.Timestamp.fromSecondsAndNanos 1700000000 123456789 }
    , { name = "", at = Proto.Timestamp.fromSecondsAndNanos 0 0 }
    ]


{-| A time proto3 JSON has no form for: past the year 9999, as only a
timestamp read from protobuf binary can be.
-}
tooLate : Proto.Timestamp.Timestamp
tooLate =
    Proto.Binary.encode (\() -> Bytes.Encode.sequence [ Proto.Binary.implicit Proto.Binary.int64AsInt 1 300000000000 ]) ()
        |> Proto.Binary.decode (Proto.Binary.messageDecoder Proto.Binary.timestamp)
        |> Result.withDefault (Proto.Timestamp.fromPosix (Time.millisToPosix 0))


{-| The error `Rpc.request` refuses a call over each of its bindings with:
nothing is sent.
-}
refusals : (req -> Rpc.Call Rpc.Json req res) -> req -> List (Maybe Rpc.Error)
refusals toCall request =
    List.range 0 2
        |> List.filterMap (\index -> Rpc.Call.viaBinding index (toCall request))
        |> List.map (refusalOf withTypes)


frees : List B.Free
frees =
    [ { name = "values/1", value = Nothing }
    , { name = "values/2", value = Just (Proto.Value.ValueStruct (Dict.fromList [ ( "a", Proto.Value.ValueNumber 1 ) ])) }
    , { name = "values/3", value = Just (Proto.Value.ValueString "s") }
    , { name = "values/4", value = Just (Proto.Value.ValueList [ Proto.Value.ValueNumber 1, Proto.Value.ValueNumber 2 ]) }
    ]


suite : Test
suite =
    describe "typed routes agree with the interpreter over the same bindings"
        [ agree "bytes held as Bytes in a path and in the query" Service.descriptorGetBlob Service.getBlob blobs
        , agree "bytes held as Bytes in a body *" Service.descriptorFindBlob Service.findBlob blobs
        , agree "a body field holding an Any, over two bindings" Service.descriptorLabelBlob Service.labelBlob labelRequests
        , agree "a body * holding an Any" Service.descriptorPutLabel Service.putLabel labeleds
        , agree "a path through a message on a cycle" Service.descriptorAddFolder Service.addFolder folders
        , agree "a body field on a cycle" Service.descriptorMoveFolder Service.moveFolder folders
        , agree "a body field of Empty" Service.descriptorTouch Service.touch [ { name = "slots/1", nothing = () }, { name = "", nothing = () } ]
        , agree "a body field of Value" Service.descriptorSetValue Service.setValue frees
        , agree "a Timestamp in a path and in the query" Service.descriptorGetMoment Service.getMoment moments
        , agree "a body * holding a Timestamp" Service.descriptorPutMoment Service.putMoment moments
        , agree "a body field holding a Timestamp" Service.descriptorStamp Service.stamp (List.map (\moment -> { shelf = "shelves/s", moment = Just moment }) moments)
        , describe "a value a JSON write refuses is refused before a route is built, typed or not"
            [ test "in a path variable, and in the query over another binding" <|
                \_ ->
                    refusals Service.getMoment { name = "moments/1", at = Just tooLate }
                        |> Expect.equal (List.repeat 2 (Just (Rpc.Error.badValue { typeName = "google.protobuf.Timestamp", path = [ "at" ], message = "the time is outside years 1 to 9999" })))
            , test "in a body *" <|
                \_ ->
                    refusals Service.putMoment { name = "moments/1", at = Just tooLate }
                        |> Expect.equal [ Just (Rpc.Error.badValue { typeName = "google.protobuf.Timestamp", path = [ "at" ], message = "the time is outside years 1 to 9999" }) ]
            , test "in a body field" <|
                \_ ->
                    refusals Service.stamp { shelf = "shelves/s", moment = Just { name = "moments/1", at = Just tooLate } }
                        |> Expect.equal [ Just (Rpc.Error.badValue { typeName = "google.protobuf.Timestamp", path = [ "moment", "at" ], message = "the time is outside years 1 to 9999" }) ]
            , test "in a Value body" <|
                \_ ->
                    refusals Service.setValue { name = "values/1", value = Just (Proto.Value.ValueList [ Proto.Value.ValueNumber 1, Proto.Value.ValueNumber (0 / 0) ]) }
                        |> Expect.equal [ Just (Rpc.Error.badValue { typeName = "google.protobuf.Value", path = [ "value" ], message = "a number is NaN or infinite" }) ]
            , test "the interpreter's route of the same binding is refused the same" <|
                \_ ->
                    [ refusalOf withTypes (interpreted Service.descriptorGetMoment (Service.getMoment { name = "moments/1", at = Just tooLate }))
                    , refusalOf withTypes (interpreted Service.descriptorSetValue (Service.setValue { name = "values/1", value = Just (Proto.Value.ValueNumber (1 / 0)) }))
                    ]
                        |> Expect.equal
                            [ Just (Rpc.Error.badValue { typeName = "google.protobuf.Timestamp", path = [ "at" ], message = "the time is outside years 1 to 9999" })
                            , Just (Rpc.Error.badValue { typeName = "google.protobuf.Value", path = [ "value" ], message = "a number is NaN or infinite" })
                            ]
            , test "over a binary protocol, which writes any value, it is sent" <|
                \_ ->
                    Rpc.request (Rpc.client Rpc.Protocol.connectProto "https://api.example.com") (Service.getMoment { name = "moments/1", at = Just tooLate })
                        |> Result.map .method
                        |> Expect.equal (Ok "POST")
            ]
        , describe "where the typed route is deliberately different"
            [ test "bytes are URL-safe base64 in a path and in the query, where the interpreter writes standard base64" <|
                \_ ->
                    both withTypes Service.descriptorGetBlob Service.getBlob { digest = bytesOf [ 0xFB, 0xFF ], name = "shelves/a/blobs/b", salt = bytesOf [ 0xFF, 0xFE ] }
                        |> Expect.equal
                            [ ( "GET https://api.example.com/x/v1/blobs/-_8%3D?name=shelves%2Fa%2Fblobs%2Fb&salt=__4%3D <none>"
                              , "GET https://api.example.com/x/v1/blobs/%2B%2F8%3D?name=shelves%2Fa%2Fblobs%2Fb&salt=%2F%2F4%3D <none>"
                              )
                            , ( "GET https://api.example.com/x/v1/shelves/a/blobs/b?digest=-_8%3D&salt=__4%3D <none>"
                              , "GET https://api.example.com/x/v1/shelves/a/blobs/b?digest=%2B%2F8%3D&salt=%2F%2F4%3D <none>"
                              )
                            ]
            , test "a Value body field set to null is sent as null, where the interpreter sent {}" <|
                \_ ->
                    both withTypes Service.descriptorSetValue Service.setValue { name = "values/5", value = Just Proto.Value.ValueNull }
                        |> Expect.equal [ ( "POST https://api.example.com/x/v1/values/5 null", "POST https://api.example.com/x/v1/values/5 {}" ) ]
            , test "a request whose Any the client cannot write is refused before either builds a route" <|
                \_ ->
                    let
                        typed =
                            Service.labelBlob { labeled = Just { name = "labels/a", label = Just packed }, shelf = "shelves/s" }
                    in
                    [ refusalOf base typed, refusalOf base (interpreted Service.descriptorLabelBlob typed) ]
                        |> List.map (Maybe.map Rpc.Error.protoError)
                        |> Expect.equal (List.repeat 2 (Just (Just (Proto.Error.UnregisteredType "type.googleapis.com/blobs.v1.Blob"))))
            ]
        ]
