module Rpc.GrpcWebTest exposing (suite)

import Answers exposing (metadata)
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode
import Bytes.Encode as E
import Dict
import Expect
import Http
import Json.Decode
import Notes exposing (GetNote, binaryOnly, both, over, titleHi)
import Octets exposing (bytesOf)
import Proto.Any
import Proto.Bytes
import Proto.Error
import Requests exposing (requestOf)
import Rpc
import Rpc.Body
import Rpc.Client
import Rpc.Code exposing (Code(..))
import Rpc.Error exposing (Cause(..), Error, Source(..))
import Rpc.Internal.Plan exposing (Reader(..))
import Rpc.Internal.Trace
import Rpc.Protocol
import Rpc.Trace
import Test exposing (Test, describe, test)


{-| A method without side effects, so that a GET would be sent if the
protocol sent one.
-}
getNote : GetNote -> Rpc.Call Rpc.Binary GetNote String
getNote =
    binaryOnly


grpcWeb : Rpc.Client Rpc.Binary
grpcWeb =
    over Rpc.Protocol.grpcWeb


decodeAll : Bytes -> List Int
decodeAll b =
    let
        step ( left, acc ) =
            if left == 0 then
                Bytes.Decode.succeed (Bytes.Decode.Done (List.reverse acc))

            else
                Bytes.Decode.map (\x -> Bytes.Decode.Loop ( left - 1, x :: acc )) Bytes.Decode.unsignedInt8
    in
    Bytes.Decode.decode (Bytes.Decode.loop ( Bytes.width b, [] ) step) b
        |> Maybe.withDefault []


frame : Int -> Bytes -> E.Encoder
frame flag payload =
    E.sequence [ E.unsignedInt8 flag, E.unsignedInt32 BE (Bytes.width payload), E.bytes payload ]


trailers : String -> E.Encoder
trailers text =
    frame 0x80 (E.encode (E.string text))


body : List E.Encoder -> Bytes
body =
    E.sequence >> E.encode


answerOver : Rpc.Client Rpc.Binary -> Int -> List ( String, String ) -> List E.Encoder -> Result Error String
answerOver client status headers frames =
    Rpc.responseBytes client (getNote { name = "hi" }) (Http.GoodStatus_ (metadata status headers) (body frames))


answer : Int -> List ( String, String ) -> List E.Encoder -> Result Error String
answer =
    answerOver grpcWeb


{-| A failure's code, message and where its status was stated, when the
server stated one.
-}
statusOf : Result Error String -> Maybe ( Code, String, Source )
statusOf result =
    case result of
        Err error ->
            Rpc.Error.source error
                |> Maybe.map (\source -> ( Rpc.Error.code error, Rpc.Error.message error, source ))

        Ok _ ->
            Nothing


{-| An answer that could not be used: its code and message.
-}
badResponseOf : Result Error String -> Maybe ( Code, String )
badResponseOf result =
    case result of
        Err error ->
            case Rpc.Error.cause error of
                BadResponse _ ->
                    Just ( Rpc.Error.code error, Rpc.Error.message error )

                _ ->
                    Nothing

        Ok _ ->
            Nothing


ok : String
ok =
    "grpc-status: 0\u{000D}\ngrpc-message: \u{000D}\n"


{-| A `google.rpc.Status` with code 5, message "gone" and two details, `Any`s
of types `google.rpc.ErrorInfo` and `google.rpc.BadRequest`, each holding
`0a 01 78`.
-}
statusWithDetails : Bytes
statusWithDetails =
    let
        any typeUrl =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 0x0A
                    , E.unsignedInt8 (String.length typeUrl)
                    , E.string typeUrl
                    , E.unsignedInt8 0x12
                    , E.unsignedInt8 3
                    , E.bytes (bytesOf [ 0x0A, 0x01, 0x78 ])
                    ]
                )

        detail typeUrl =
            E.sequence [ E.unsignedInt8 0x1A, E.unsignedInt8 (Bytes.width (any typeUrl)), E.bytes (any typeUrl) ]
    in
    E.encode
        (E.sequence
            [ E.bytes (bytesOf [ 0x08, 0x05, 0x12, 0x04 ])
            , E.string "gone"
            , detail "type.googleapis.com/google.rpc.ErrorInfo"
            , detail "type.googleapis.com/google.rpc.BadRequest"
            ]
        )


headerNamed : String -> Rpc.Request -> List ( String, String )
headerNamed name sent =
    List.filter (\( key, _ ) -> key == name) sent.headers


suite : Test
suite =
    describe "gRPC-Web"
        [ requests
        , answers
        , limits
        , traces
        ]


requests : Test
requests =
    describe "requests"
        [ test "a POST of one framed message, with gRPC-Web's headers" <|
            \_ ->
                requestOf grpcWeb (getNote { name = "hi" })
                    |> Expect.all
                        [ \r -> r.method |> Expect.equal "POST"
                        , \r -> r.url |> Expect.equal "https://api.example.com/notes.v1.Notes/GetNote"
                        , \r -> r.headers |> Expect.equal [ ( "X-Grpc-Web", "1" ) ]
                        , \r -> Rpc.Body.contentType r.body |> Expect.equal (Just "application/grpc-web+proto")
                        , \r -> Rpc.Body.toBytes r.body |> Maybe.map decodeAll |> Expect.equal (Just [ 0, 0, 0, 0, 4, 0x0A, 0x02, 0x68, 0x69 ])
                        ]
        , test "an empty message is a frame of length 0" <|
            \_ ->
                (requestOf grpcWeb (getNote { name = "" })).body
                    |> Rpc.Body.toBytes
                    |> Maybe.map decodeAll
                    |> Expect.equal (Just [ 0, 0, 0, 0, 0 ])
        , test "the client's headers come first, then the call's, then gRPC-Web's" <|
            \_ ->
                (requestOf (grpcWeb |> Rpc.Client.withHeaders [ ( "A", "1" ) ]) (getNote { name = "" })).headers
                    |> Expect.equal [ ( "A", "1" ), ( "X-Grpc-Web", "1" ) ]
        , test "a timeout is grpc-timeout, milliseconds rounded up" <|
            \_ ->
                requestOf (Rpc.Client.withTimeout 1500.2 grpcWeb) (getNote { name = "" })
                    |> Expect.all
                        [ headerNamed "grpc-timeout" >> Expect.equal [ ( "grpc-timeout", "1501m" ) ]
                        , headerNamed "Connect-Timeout-Ms" >> Expect.equal []
                        , .timeout >> Expect.equal (Just 1500.2)
                        ]
        , test "a timeout past eight digits of milliseconds is in seconds, past eight of seconds in hours" <|
            \_ ->
                [ 99999999, 100000000, 1.0e12 ]
                    |> List.map (\ms -> headerNamed "grpc-timeout" (requestOf (Rpc.Client.withTimeout ms grpcWeb) (getNote { name = "" })))
                    |> Expect.equal [ [ ( "grpc-timeout", "99999999m" ) ], [ ( "grpc-timeout", "100000S" ) ], [ ( "grpc-timeout", "277778H" ) ] ]
        , test "a timeout that is not a positive number is none, and no header" <|
            \_ ->
                requestOf (Rpc.Client.withTimeout 0 grpcWeb) (getNote { name = "" })
                    |> headerNamed "grpc-timeout"
                    |> Expect.equal []
        , test "a retry budget rewrites grpc-timeout" <|
            \_ ->
                let
                    c =
                        getNote { name = "" }

                    client =
                        Rpc.Client.withTimeout 1000 grpcWeb
                in
                requestOf client c
                    |> Rpc.Internal.Plan.withBudget (Rpc.Internal.Plan.plan client c) (Just 299.5)
                    |> Expect.all
                        [ headerNamed "grpc-timeout" >> Expect.equal [ ( "grpc-timeout", "300m" ) ]
                        , .timeout >> Expect.equal (Just 299.5)
                        ]
        , test "withConnectGet and withMaxGetUrl leave it as it was: a method without side effects is POSTed" <|
            \_ ->
                ( (requestOf (over (Rpc.Protocol.grpcWeb |> Rpc.Protocol.withConnectGet |> Rpc.Protocol.withMaxGetUrl 10)) (getNote { name = "hi" })).method
                , (Rpc.Protocol.grpcWeb |> Rpc.Protocol.withConnectGet |> Rpc.Protocol.withMaxGetUrl 10) == Rpc.Protocol.grpcWeb
                )
                    |> Expect.equal ( "POST", True )
        , test "a method with both codecs is sent as its binary" <|
            \_ ->
                (requestOf grpcWeb (both { name = "hi" })).body
                    |> Rpc.Body.toBytes
                    |> Maybe.map decodeAll
                    |> Expect.equal (Just [ 0, 0, 0, 0, 4, 0x0A, 0x02, 0x68, 0x69 ])
        , test "its name and codec" <|
            \_ ->
                ( Rpc.Protocol.name Rpc.Protocol.grpcWeb, Rpc.Protocol.codec Rpc.Protocol.grpcWeb )
                    |> Expect.equal ( "grpc-web", "proto" )
        ]


answers : Test
answers =
    describe "answers"
        [ test "a message and status 0 in the trailers" <|
            \_ ->
                answer 200 [ ( "content-type", "application/grpc-web+proto" ) ] [ frame 0 titleHi, trailers ok ]
                    |> Expect.equal (Ok "hi")
        , test "an error in the trailers, its message percent-decoded" <|
            \_ ->
                answer 200 [] [ trailers "Grpc-Status: 5\u{000D}\ngrpc-message: no%20such%20note%20%E2%80%94%20gone\u{000D}\n" ]
                    |> statusOf
                    |> Expect.equal (Just ( NotFound, "no such note — gone", GrpcTrailers ))
        , test "a grpc-message that is not well-formed percent-encoding is kept as it came" <|
            \_ ->
                answer 200 [] [ trailers "grpc-status: 3\u{000D}\ngrpc-message: 100%\u{000D}\n" ]
                    |> statusOf
                    |> Expect.equal (Just ( InvalidArgument, "100%", GrpcTrailers ))
        , test "a trailers-only answer: the status in the headers, whatever their case" <|
            \_ ->
                answer 200 [ ( "Grpc-Status", "7" ), ( "grpc-message", "denied%21" ) ] []
                    |> statusOf
                    |> Expect.equal (Just ( PermissionDenied, "denied!", GrpcHeaders ))
        , test "a body's trailers win over its headers" <|
            \_ ->
                answer 200 [ ( "grpc-status", "7" ) ] [ frame 0 titleHi, trailers ok ]
                    |> Expect.equal (Ok "hi")
        , test "grpc-status-details-bin gives the error's details, in order" <|
            \_ ->
                case answer 200 [] [ trailers ("grpc-status: 5\u{000D}\ngrpc-message: gone\u{000D}\ngrpc-status-details-bin: " ++ Proto.Bytes.toBase64 statusWithDetails ++ "\u{000D}\n") ] of
                    Err error ->
                        List.map (Result.map Proto.Any.typeUrl) (Rpc.Error.details error)
                            |> Expect.equal [ Ok "type.googleapis.com/google.rpc.ErrorInfo", Ok "type.googleapis.com/google.rpc.BadRequest" ]

                    other ->
                        Expect.fail (Debug.toString other)
        , test "a Status in grpc-status-details-bin gives the error's code and message, over the trailers'" <|
            \_ ->
                case answer 200 [] [ trailers ("grpc-status: 5\u{000D}\ngrpc-message: gone\u{000D}\ngrpc-status-details-bin: " ++ Proto.Bytes.toBase64 (bytesOf [ 0x08, 0x07, 0x12, 0x04, 0x6E, 0x6F, 0x70, 0x65 ]) ++ "\u{000D}\n") ] of
                    Err error ->
                        ( Rpc.Error.code error, Rpc.Error.message error, Rpc.Error.details error ) |> Expect.equal ( PermissionDenied, "nope", [] )

                    other ->
                        Expect.fail (Debug.toString other)
        , test "a Status without a code leaves the trailers' code and message standing" <|
            \_ ->
                case answer 200 [] [ trailers ("grpc-status: 5\u{000D}\ngrpc-message: gone\u{000D}\ngrpc-status-details-bin: " ++ Proto.Bytes.toBase64 (bytesOf [ 0x12, 0x04, 0x6E, 0x6F, 0x70, 0x65 ]) ++ "\u{000D}\n") ] of
                    Err error ->
                        ( Rpc.Error.code error, Rpc.Error.message error ) |> Expect.equal ( NotFound, "gone" )

                    other ->
                        Expect.fail (Debug.toString other)
        , test "a grpc-status-details-bin that is base64 but not a Status is one problem standing for all, the status kept" <|
            \_ ->
                case answer 200 [] [ trailers "grpc-status: 5\u{000D}\ngrpc-message: gone\u{000D}\ngrpc-status-details-bin: CA==\u{000D}\n" ] of
                    Err error ->
                        case ( Rpc.Error.code error, Rpc.Error.message error, Rpc.Error.details error ) of
                            ( NotFound, "gone", [ Err (Proto.Error.BadBinary problem) ] ) ->
                                problem.typeName |> Expect.equal "google.rpc.Status"

                            other ->
                                Expect.fail (Debug.toString other)

                    other ->
                        Expect.fail (Debug.toString other)
        , test "a grpc-status-details-bin that is not base64 is a BadResponse whose code is Internal" <|
            \_ ->
                case answer 200 [] [ trailers "grpc-status: 5\u{000D}\ngrpc-message: gone\u{000D}\ngrpc-status-details-bin: !!\u{000D}\n" ] of
                    Err error ->
                        badResponseOf (Err error)
                            |> Expect.equal (Just ( Internal, "bad response: a grpc-status-details-bin trailer that is not base64" ))

                    other ->
                        Expect.fail (Debug.toString other)
        , test "details in a trailers-only answer's headers, their base64 unpadded" <|
            \_ ->
                case answer 200 [ ( "grpc-status", "5" ), ( "grpc-status-details-bin", String.replace "=" "" (Proto.Bytes.toBase64 statusWithDetails) ) ] [] of
                    Err error ->
                        ( Rpc.Error.source error, List.length (Rpc.Error.details error) )
                            |> Expect.equal ( Just GrpcHeaders, 2 )

                    other ->
                        Expect.fail (Debug.toString other)
        , test "an unknown status number is Unknown" <|
            \_ ->
                answer 200 [] [ trailers "grpc-status: 99\u{000D}\n" ]
                    |> statusOf
                    |> Expect.equal (Just ( Unknown, "", GrpcTrailers ))
        , test "status 0 without a message, or with two, is a BadResponse whose code is Unimplemented" <|
            \_ ->
                [ answer 200 [] [ trailers ok ]
                , answer 200 [ ( "grpc-status", "0" ) ] []
                , answer 200 [] [ frame 0 titleHi, frame 0 titleHi, trailers ok ]
                ]
                    |> List.map badResponseOf
                    |> Expect.equal
                        [ Just ( Unimplemented, "bad response: a unary gRPC-Web answer with status 0 and no message" )
                        , Just ( Unimplemented, "bad response: a unary gRPC-Web answer with status 0 and no message" )
                        , Just ( Unimplemented, "bad response: a unary gRPC-Web answer with status 0 and more than one message" )
                        ]
        , test "a body without trailers is a BadResponse whose code is Internal" <|
            \_ ->
                answer 200 [] [ frame 0 titleHi ]
                    |> badResponseOf
                    |> Expect.equal (Just ( Internal, "bad response: a gRPC-Web answer without trailers" ))
        , test "no grpc-status anywhere is a BadResponse" <|
            \_ ->
                [ answer 200 [] [ frame 0 titleHi ], answer 200 [] [ frame 0 titleHi, trailers "grpc-message: x\u{000D}\n" ], answer 200 [] [] ]
                    |> List.map badResponseOf
                    |> Expect.equal [ Just ( Internal, "bad response: a gRPC-Web answer without trailers" ), Just ( Internal, "bad response: a gRPC-Web answer without a numeric grpc-status" ), Just ( Internal, "bad response: a gRPC-Web answer without a numeric grpc-status" ) ]
        , test "a compressed message, or a frame running past the end, is a BadResponse" <|
            \_ ->
                [ answer 200 [] [ frame 1 titleHi, trailers ok ]
                , answer 200 [] [ frame 0 titleHi, E.unsignedInt8 0x80, E.unsignedInt32 BE 100 ]
                , answer 200 [] [ frame 0 titleHi, E.unsignedInt8 0 ]
                ]
                    |> List.map badResponseOf
                    |> Expect.equal [ Just ( Internal, "bad response: a gRPC-Web body that is not a sequence of uncompressed frames" ), Just ( Internal, "bad response: a gRPC-Web body that is not a sequence of uncompressed frames" ), Just ( Internal, "bad response: a gRPC-Web body that is not a sequence of uncompressed frames" ) ]
        , test "a message that is not the response is a BadResponse saying why" <|
            \_ ->
                case answer 200 [] [ frame 0 (bytesOf [ 0x0A, 0x05 ]), trailers ok ] of
                    Err error ->
                        ( badResponseOf (Err error), Rpc.Error.protoError error )
                            |> Expect.equal
                                ( Just ( Internal, "bad response body" )
                                , Just (Proto.Error.BadBinary { typeName = "notes.v1.Title", reason = Proto.Error.Truncated, path = [ ( "notes.v1.Title", 1 ) ], offset = 1 })
                                )

                    other ->
                        Expect.fail (Debug.toString other)
        , test "a 200 as application/grpc-web, or of no content type, is read as gRPC-Web" <|
            \_ ->
                [ answer 200 [ ( "Content-Type", "application/grpc-web" ) ] [ frame 0 titleHi, trailers ok ]
                , answer 200 [ ( "content-type", "application/grpc-web+proto; charset=x" ) ] [ frame 0 titleHi, trailers ok ]
                , answer 200 [] [ frame 0 titleHi, trailers ok ]
                ]
                    |> Expect.equal [ Ok "hi", Ok "hi", Ok "hi" ]
        , test "a 200 of another gRPC-Web content type is a BadResponse naming the ones read" <|
            \_ ->
                [ answer 200 [ ( "content-type", "application/grpc-web+json" ) ] [ frame 0 titleHi, trailers ok ]
                , answer 200 [ ( "content-type", "application/grpc-web-text" ) ] []
                ]
                    |> List.map (Result.mapError Rpc.Error.message)
                    |> Expect.equal
                        [ Err "bad response: content-type application/grpc-web+json, not application/grpc-web or application/grpc-web+proto"
                        , Err "bad response: content-type application/grpc-web-text, not application/grpc-web or application/grpc-web+proto"
                        ]
        , test "a 200 that is not gRPC-Web's is read as a failure: code Unknown, when it states no status" <|
            \_ ->
                Rpc.responseBytes grpcWeb (getNote { name = "" }) (Http.GoodStatus_ (metadata 200 [ ( "content-type", "text/html" ) ]) (E.encode (E.string "<html></html>")))
                    |> Expect.equal
                        (Err
                            (Rpc.Error.fromResponse
                                { url = "https://api.example.com/notes.v1.Notes/GetNote"
                                , statusCode = 200
                                , statusText = ""
                                , headers = Dict.fromList [ ( "content-type", "text/html" ) ]
                                , body = Rpc.Body.text "<html></html>"
                                }
                            )
                        )
        , test "a 200 that is not gRPC-Web's is read as a failure: its grpc-status headers or Connect body are the error" <|
            \_ ->
                [ answer 200 [ ( "content-type", "text/plain" ), ( "grpc-status", "14" ), ( "grpc-message", "down" ) ] []
                , Rpc.responseBytes grpcWeb (getNote { name = "" }) (Http.GoodStatus_ (metadata 200 [ ( "content-type", "image/jpeg" ) ]) (E.encode (E.string "{\"code\":\"unavailable\",\"message\":\"down\"}")))
                ]
                    |> List.map statusOf
                    |> Expect.equal [ Just ( Unavailable, "down", GrpcHeaders ), Just ( Unavailable, "down", ConnectBody ) ]
        , test "another HTTP status with grpc-status headers is read from them" <|
            \_ ->
                Rpc.responseBytes grpcWeb (getNote { name = "" }) (Http.BadStatus_ (metadata 503 [ ( "grpc-status", "14" ) ]) (body []))
                    |> statusOf
                    |> Maybe.map (\( code, _, source ) -> ( code, source ))
                    |> Expect.equal (Just ( Unavailable, GrpcHeaders ))
        , test "another HTTP status without them states no status" <|
            \_ ->
                Rpc.responseBytes grpcWeb (getNote { name = "" }) (Http.BadStatus_ (metadata 404 []) (body []))
                    |> Result.mapError (\error -> ( Rpc.Error.source error, Rpc.Error.httpStatus error ))
                    |> Expect.equal (Err ( Nothing, Just 404 ))
        , test "no answer is the error it is" <|
            \_ ->
                [ Http.Timeout_, Http.NetworkError_, Http.BadUrl_ "x" ]
                    |> List.map (Rpc.responseBytes grpcWeb (getNote { name = "" }))
                    |> Expect.equal
                        [ Err Rpc.Error.timeout
                        , Err Rpc.Error.networkError
                        , Err (Rpc.Error.badCall Internal "bad URL: the browser could not read it")
                        ]
        ]


limits : Test
limits =
    describe "size limits count the message's bytes, not its frame's"
        [ test "read: a message at the limit is read, one byte over is refused" <|
            \_ ->
                [ 4, 3 ]
                    |> List.map (\limit -> answerOver (over (Rpc.Protocol.withReadMaxBytes limit Rpc.Protocol.grpcWeb)) 200 [] [ frame 0 titleHi, trailers ok ])
                    |> Expect.equal
                        [ Ok "hi"
                        , Err
                            (Rpc.Error.badResponse ResourceExhausted
                                "message size 4 is larger than configured readMaxBytes 3"
                                { url = "https://api.example.com/notes.v1.Notes/GetNote"
                                , statusCode = 200
                                , statusText = ""
                                , headers = Dict.fromList [ ( "trailer-grpc-status", "0" ), ( "trailer-grpc-message", "" ) ]
                                , body = Rpc.Body.none
                                }
                            )
                        ]
        , test "read: an error is read whatever the limit" <|
            \_ ->
                answerOver (over (Rpc.Protocol.withReadMaxBytes 1 Rpc.Protocol.grpcWeb)) 200 [] [ trailers "grpc-status: 5\u{000D}\ngrpc-message: a long message\u{000D}\n" ]
                    |> statusOf
                    |> Expect.equal (Just ( NotFound, "a long message", GrpcTrailers ))
        , test "write: the message is measured" <|
            \_ ->
                [ 4, 3 ]
                    |> List.map (\limit -> (Rpc.Internal.Plan.plan (over (Rpc.Protocol.withWriteMaxBytes limit Rpc.Protocol.grpcWeb)) (getNote { name = "hi" })).tooLarge ())
                    |> Expect.equal [ Nothing, Just { limit = 3, size = 4 } ]
        ]


traces : Test
traces =
    let
        traced : Http.Response Bytes -> Rpc.Trace.Trace
        traced response =
            let
                c =
                    getNote { name = "x" }

                plan =
                    Rpc.Internal.Plan.plan grpcWeb c

                ( read, result ) =
                    case plan.reader of
                        BytesReader reader ->
                            reader response

                        TextReader _ ->
                            ( Nothing, Err (Rpc.Error.badResponse Internal "read as text" { url = "", statusCode = 0, statusText = "", headers = Dict.empty, body = Rpc.Body.none }) )
            in
            Rpc.Internal.Trace.init (Rpc.Client.protocol grpcWeb) c plan (Result.withDefault (plan.unwritten ()) (plan.request ())) { attempts = 1, metadata = read, result = result } 1
    in
    describe "a trace of a call"
        [ test "names the protocol and codec, and gives the request's frame as base64" <|
            \_ ->
                traced (Http.GoodStatus_ (metadata 200 []) (body [ frame 0 titleHi, trailers ok ]))
                    |> Expect.all
                        [ Rpc.Trace.protocol >> Expect.equal "grpc-web"
                        , Rpc.Trace.codec >> Expect.equal "proto"
                        , Rpc.Trace.toJson
                            >> Json.Decode.decodeValue (Json.Decode.at [ "request", "bodyBase64" ] Json.Decode.string)
                            >> Expect.equal (Ok "AAAAAAMKAXg=")
                        ]
        , test "gives the body's trailers as trailers, and the headers apart" <|
            \_ ->
                traced (Http.GoodStatus_ (metadata 200 [ ( "content-type", "application/grpc-web+proto" ) ]) (body [ frame 0 titleHi, trailers "grpc-status: 0\u{000D}\nX-Custom: done\u{000D}\n" ]))
                    |> Expect.all
                        [ Rpc.Trace.trailers >> Expect.equal (Dict.fromList [ ( "grpc-status", "0" ), ( "x-custom", "done" ) ])
                        , Rpc.Trace.headers >> Expect.equal (Dict.fromList [ ( "content-type", "application/grpc-web+proto" ) ])
                        , Rpc.Trace.code >> Expect.equal Nothing
                        ]
        , test "an error in the trailers gives its code and the trailers" <|
            \_ ->
                traced (Http.GoodStatus_ (metadata 200 []) (body [ trailers "grpc-status: 5\u{000D}\ngrpc-message: gone\u{000D}\n" ]))
                    |> Expect.all
                        [ Rpc.Trace.code >> Expect.equal (Just NotFound)
                        , Rpc.Trace.trailers >> Dict.get "grpc-message" >> Expect.equal (Just "gone")
                        ]
        , test "a trailers-only answer's status stays in its headers" <|
            \_ ->
                traced (Http.GoodStatus_ (metadata 200 [ ( "grpc-status", "7" ) ]) (body []))
                    |> Expect.all
                        [ Rpc.Trace.trailers >> Expect.equal Dict.empty
                        , Rpc.Trace.headers >> Dict.get "grpc-status" >> Expect.equal (Just "7")
                        ]
        ]
