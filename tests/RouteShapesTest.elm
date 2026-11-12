module RouteShapesTest exposing (suite)

{-| Every binding shape whose route function was once left to the
interpreter (the corpus case `routes_typed_shapes`, generated into
`tests/Shapes` by `crates/elm-connect-gen/tests/routes.rs`): each method's
typed routes against the interpreter over the same bindings as data
(`Proto.Method.withBindings`), through `Rpc.request` over transcoding, for
every binding and a spread of requests. The two agree but where the typed
route is deliberately different, which the last tests pin.
-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Expect
import Json.Encode
import Proto.Any
import Proto.Method
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Protocol
import Shapes.Blobs.V1 as B
import Shapes.Blobs.V1.BlobService as Service
import Test exposing (Test, describe, test)


base : Rpc.Client Rpc.Json
base =
    Rpc.client Rpc.Protocol.transcode "https://api.example.com/x"


withTypes : Rpc.Client Rpc.Json
withTypes =
    Rpc.withRegistry B.registry base


show : Rpc.Client Rpc.Json -> Rpc.Call Rpc.Json req res -> String
show client call =
    let
        request =
            Rpc.request client call
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


{-| A shown request's method and URL.
-}
withoutBody : String -> String
withoutBody shown =
    String.join " " (List.take 2 (String.words shown))


bytesOf : List Int -> Bytes
bytesOf ints =
    Bytes.Encode.encode (Bytes.Encode.sequence (List.map Bytes.Encode.unsignedInt8 ints))


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


frees : List B.Free
frees =
    [ { name = "values/1", value = Nothing }
    , { name = "values/2", value = Just (Json.Encode.object [ ( "a", Json.Encode.int 1 ) ]) }
    , { name = "values/3", value = Just (Json.Encode.string "s") }
    , { name = "values/4", value = Just (Json.Encode.list Json.Encode.int [ 1, 2 ]) }
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
                    both withTypes Service.descriptorSetValue Service.setValue { name = "values/5", value = Just Json.Encode.null }
                        |> Expect.equal [ ( "POST https://api.example.com/x/v1/values/5 null", "POST https://api.example.com/x/v1/values/5 {}" ) ]
            , test "a request whose Any the client cannot write keeps its path and query, where the interpreter's has none" <|
                \_ ->
                    both base Service.descriptorLabelBlob Service.labelBlob { labeled = Just { name = "labels/a", label = Just packed }, shelf = "shelves/s" }
                        |> List.map (Tuple.mapBoth withoutBody withoutBody)
                        |> Expect.equal
                            [ ( "POST https://api.example.com/x/v1/shelves/s/labels", "POST https://api.example.com/x/v1//labels" )
                            , ( "PUT https://api.example.com/x/v1/labels/a?shelf=shelves%2Fs", "PUT https://api.example.com/x/v1/" )
                            ]
            ]
        ]
