module RpcFuzzTest exposing (suite)

{-| Structural laws of `Rpc.request` over the Transcode transport, fuzzed over
requests to methods of the generated `Routes.V1.Routes`: a path variable's
segment percent-decodes to its value, a field bound in the path is in neither
the query nor a `*` body, a field in the body is not in the query, and the URL
holds nothing a URL may not. The route fixtures (`RouteFixturesTest`) and the
route properties (`RoutePropertiesTest`) pin exact requests.
-}

import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer)
import Fuzzers
import Json.Decode
import Json.Encode
import Routes.V1
import Routes.V1.Routes
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Transport
import Test exposing (Test, describe, fuzz)


suite : Test
suite =
    describe "Rpc.request over Transcode, fuzzed"
        [ singleSegment
        , multiSegment
        , boundFields
        , typedPath
        , bodies
        , queryValues
        , urlCharacters
        ]


transcode : Rpc.Config
transcode =
    let
        base =
            Rpc.config ""
    in
    { base | transport = Rpc.Transport.transcode }


send : (req -> Rpc.Call req res) -> req -> Rpc.Request
send method message =
    Rpc.request transcode (method message)


{-| The request over binding `index`; the binding of binding 0 when the method
has no such binding, which the tests below never ask for.
-}
sendVia : Int -> (req -> Rpc.Call req res) -> req -> Rpc.Request
sendVia index method message =
    Rpc.Call.viaBinding index (method message)
        |> Maybe.withDefault (method message)
        |> Rpc.request transcode


{-| A request's URL as its path, split at `/`, and its query pairs, both still
percent-encoded.
-}
type alias Url =
    { segments : List String
    , query : List ( String, String )
    }


url : Rpc.Request -> Url
url request =
    let
        ( path, query ) =
            case String.split "?" request.url of
                [ p ] ->
                    ( p, "" )

                p :: rest ->
                    ( p, String.join "?" rest )

                [] ->
                    ( "", "" )
    in
    { segments = String.split "/" path |> List.drop 1
    , query =
        if String.isEmpty query then
            []

        else
            String.split "&" query
                |> List.map
                    (\pair ->
                        case String.split "=" pair of
                            [ name, value ] ->
                                ( name, value )

                            _ ->
                                ( pair, "<no single =>" )
                    )
    }


decoded : String -> Maybe String
decoded =
    Fuzzers.percentDecode


{-| The query's names, percent-decoded.
-}
queryNames : Rpc.Request -> List String
queryNames request =
    (url request).query |> List.filterMap (Tuple.first >> decoded)



-- PATH VARIABLES


singleSegment : Test
singleSegment =
    fuzz (Fuzzers.everything Fuzzers.float) "a single-segment variable is one segment that percent-decodes to its value" <|
        \x ->
            case (url (send Routes.V1.Routes.single x)).segments of
                [ "v1", "single", segment ] ->
                    Expect.all
                        [ \_ -> decoded segment |> Expect.equal (Just x.name)
                        , \_ -> String.contains "/" segment |> Expect.equal False
                        ]
                        ()

                other ->
                    Expect.fail ("the path is " ++ String.join "/" other)


multiSegment : Test
multiSegment =
    describe "a multi-segment variable keeps / and percent-decodes to its value"
        [ fuzz (Fuzzers.everything Fuzzers.float) "{name=things/*}" <|
            \x ->
                (url (send Routes.V1.Routes.multi x)).segments
                    |> List.drop 1
                    |> String.join "/"
                    |> decoded
                    |> Expect.equal (Just x.name)
        , fuzz Fuzzers.awkwardString "{path=files/**}" <|
            \path ->
                let
                    request =
                        send Routes.V1.Routes.files { path = path }
                in
                Expect.all
                    [ \_ ->
                        (url request).segments
                            |> List.drop 1
                            |> String.join "/"
                            |> decoded
                            |> Expect.equal (Just path)
                    , \_ -> List.length (String.split "/" request.url) |> Expect.equal (List.length (String.split "/" path) + 2)
                    ]
                    ()
        ]


boundFields : Test
boundFields =
    fuzz Fuzzers.getMessageRequest "fields in the path are not in the query, and the rest are, when set" <|
        \x ->
            let
                request =
                    sendVia 1 Routes.V1.Routes.getMessage x

                subfield =
                    Maybe.map .subfield x.sub |> Maybe.withDefault ""

                expected =
                    [ ( "revision", x.revision, "0" ), ( "user_id", x.userId, "" ), ( "name", x.name, "" ) ]
                        |> List.filter (\( _, value, zero ) -> value /= zero)
                        |> List.map (\( name, value, _ ) -> ( Just name, Just value ))
            in
            Expect.all
                [ \_ ->
                    (url request).segments
                        |> List.map decoded
                        |> Expect.equal [ Just "v1", Just "messages", Just x.messageId, Just subfield ]
                , \_ ->
                    (url request).query
                        |> List.map (Tuple.mapBoth decoded decoded)
                        |> Expect.equal expected
                ]
                ()


typedPath : Test
typedPath =
    fuzz (Fuzzers.everything Fuzzers.float) "typed path values are written as proto3 JSON writes them, unquoted" <|
        \x ->
            let
                kindName =
                    case x.kind of
                        Routes.V1.KindUnspecified ->
                            "KIND_UNSPECIFIED"

                        Routes.V1.KindText ->
                            "KIND_TEXT"

                        Routes.V1.KindImage ->
                            "KIND_IMAGE"

                b =
                    x.inner |> Maybe.andThen .deep |> Maybe.map .b |> Maybe.withDefault 0
            in
            (url (send Routes.V1.Routes.typed x)).segments
                |> List.map decoded
                |> Expect.equal
                    (List.map Just
                        [ "v1"
                        , "typed"
                        , String.fromInt x.count
                        , if x.flag then
                            "true"

                          else
                            "false"
                        , kindName
                        , x.big
                        , String.fromInt b
                        ]
                    )



-- BODIES


bodies : Test
bodies =
    describe "bodies"
        [ fuzz Fuzzers.getMessageRequest "body * holds every field but those in the path" <|
            \x ->
                let
                    request =
                        send Routes.V1.Routes.postSub x
                in
                Expect.all
                    [ \_ ->
                        Rpc.Body.toText request.body
                            |> Maybe.map (Json.Decode.decodeString Routes.V1.decodeGetMessageRequest)
                            |> Expect.equal (Just (Ok { x | sub = Maybe.map (\_ -> { subfield = "" }) x.sub }))
                    , \_ ->
                        Rpc.Body.toText request.body
                            |> Maybe.map (Json.Decode.decodeString (Json.Decode.at [ "sub", "subfield" ] Json.Decode.value) >> Result.toMaybe >> Maybe.map (Json.Encode.encode 0))
                            |> Expect.equal (Just Nothing)
                    , \_ -> (url request).query |> Expect.equal []
                    ]
                    ()
        , fuzz (Fuzz.pair (Fuzz.maybe (Fuzzers.resource niceFloat)) (Fuzz.maybe (Fuzz.list Fuzzers.fieldMaskPath))) "a body field is the body, and is not in the query" <|
            \( resource, mask ) ->
                let
                    request =
                        send Routes.V1.Routes.updateResource { resource = resource, updateMask = mask }
                in
                Expect.all
                    [ \_ ->
                        Rpc.Body.toText request.body
                            |> Maybe.map (Json.Decode.decodeString Routes.V1.decodeResource)
                            |> Expect.equal (Just (Ok (Maybe.withDefault Routes.V1.defaultResource resource)))
                    , \_ ->
                        queryNames request
                            |> List.filter (String.startsWith "resource")
                            |> Expect.equal []
                    , \_ ->
                        (url request).segments
                            |> List.drop 1
                            |> String.join "/"
                            |> decoded
                            |> Expect.equal (Just (resource |> Maybe.map .name |> Maybe.withDefault ""))
                    ]
                    ()
        , fuzz (Fuzzers.resource niceFloat) "body * holds map fields whole" <|
            \x ->
                send Routes.V1.Routes.cancel x
                    |> .body
                    |> Rpc.Body.toText
                    |> Maybe.map (Json.Decode.decodeString Routes.V1.decodeResource)
                    |> Expect.equal (Just (Ok { x | name = "" }))
        , fuzz (Fuzz.pair Fuzzers.awkwardString (Fuzz.maybe (Fuzz.map2 Routes.V1.Message Fuzzers.awkwardString Fuzzers.awkwardString))) "a body field holding the path's field leaves the query empty" <|
            \( messageId, message ) ->
                let
                    request =
                        send Routes.V1.Routes.updateMessage { messageId = messageId, message = message }
                in
                Expect.all
                    [ \_ -> (url request).query |> Expect.equal []
                    , \_ ->
                        Rpc.Body.toText request.body
                            |> Maybe.map (Json.Decode.decodeString Routes.V1.decodeMessage)
                            |> Expect.equal (Just (Ok (Maybe.withDefault Routes.V1.defaultMessage message)))
                    ]
                    ()
        ]


{-| A finite float other than `-0`, which compares equal after a round trip.
-}
niceFloat : Fuzzer Float
niceFloat =
    Fuzz.map
        (\x ->
            if isNaN x || isInfinite x then
                0

            else
                x
        )
        Fuzzers.nonNegativeZeroFloat



-- QUERY


queryValues : Test
queryValues =
    fuzz (Fuzzers.everything Fuzzers.float) "a repeated field is one pair per element, in order, each decoding to it" <|
        \x ->
            let
                pairs =
                    (url (send Routes.V1.Routes.query x)).query
                        |> List.map (Tuple.mapBoth decoded decoded)

                valuesOf name =
                    List.filterMap
                        (\( n, v ) ->
                            if n == Just name then
                                Just v

                            else
                                Nothing
                        )
                        pairs
            in
            Expect.all
                [ \_ -> valuesOf "tags" |> Expect.equal (List.map Just x.tags)
                , \_ -> valuesOf "numbers" |> Expect.equal (List.map (String.fromInt >> Just) x.numbers)
                , \_ ->
                    valuesOf "name"
                        |> Expect.equal
                            (if x.name == "" then
                                []

                             else
                                [ Just x.name ]
                            )
                , \_ -> List.filter (\( n, v ) -> n == Nothing || v == Nothing) pairs |> Expect.equal []
                ]
                ()



-- URLS


{-| Every request the fuzzers make, over every binding they use.
-}
requests : Fuzzer ( String, Rpc.Request )
requests =
    let
        everything =
            Fuzzers.everything Fuzzers.float
    in
    Fuzz.oneOf
        [ Fuzz.map (\x -> ( "Query", send Routes.V1.Routes.query x )) everything
        , Fuzz.map (\x -> ( "Single", send Routes.V1.Routes.single x )) everything
        , Fuzz.map (\x -> ( "Multi", send Routes.V1.Routes.multi x )) everything
        , Fuzz.map (\x -> ( "Typed", send Routes.V1.Routes.typed x )) everything
        , Fuzz.map2 (\index x -> ( "GetMessage " ++ String.fromInt index, sendVia index Routes.V1.Routes.getMessage x ))
            (Fuzz.intRange 0 3)
            Fuzzers.getMessageRequest
        , Fuzz.map (\x -> ( "PostSub", send Routes.V1.Routes.postSub x )) Fuzzers.getMessageRequest
        , Fuzz.map (\x -> ( "Cancel", send Routes.V1.Routes.cancel x )) (Fuzzers.resource Fuzzers.float)
        , Fuzz.map (\x -> ( "Files", send Routes.V1.Routes.files { path = x } )) Fuzzers.awkwardString
        ]


urlCharacters : Test
urlCharacters =
    fuzz requests "a URL holds only unreserved characters, escapes, and the delimiters it is built with" <|
        \( name, request ) ->
            request.url
                |> String.filter (\char -> not (Char.isAlphaNum char && Char.toCode char < 128 || String.contains (String.fromChar char) "-._~%/?&=:"))
                |> Expect.equal ""
                |> Expect.onFail (name ++ ": " ++ request.url)
