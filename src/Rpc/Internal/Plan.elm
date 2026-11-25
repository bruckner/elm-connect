module Rpc.Internal.Plan exposing (Plan, Reader(..), checked, plan, refused, toSend, withBudget)

{-| How a call goes over a client's protocol: the one place a call's method
meets the protocol's functions. Not exposed; `Rpc` sends through it.

A call's [`plan`](#plan) is what the protocol's kind of wire, text or bytes,
makes of the method's codecs: monomorphic from there on, so the rest of
sending is ordinary functions over it. The only branches every program
carries are that two-way choice here and the choice of elm/http's reader of
text or of bytes where the answer is read.

A method holds both codec halves, the one it was not built with a filler
(`Proto.Internal.Method`), and the codec phantom keeps a protocol from
meeting a method whose half it reads is a filler, so the plan reads the half
its wire speaks without asking which halves are real.

-}

import Bytes exposing (Bytes)
import Http
import Json.Decode exposing (Decoder)
import Json.Encode
import Proto.Error
import Proto.Internal.Method exposing (Method(..), RouteShape(..))
import Proto.Registry exposing (Registry)
import Proto.Route exposing (PathError)
import Rpc.Code as Code
import Rpc.Error as Error exposing (Error)
import Rpc.Internal.Call exposing (Call(..))
import Rpc.Internal.Client exposing (Client(..))
import Rpc.Internal.Http as Internal
import Rpc.Internal.Protocol exposing (GoodText, Protocol(..), Size, Wire(..))
import Rpc.Internal.Retry as Retry
import Rpc.Internal.Status as Status
import Rpc.Request exposing (Request)


{-| A call over a protocol:

  - `request`: the request it sends, built when asked for, or, over JSON,
    why its request has no proto3 JSON (`unencodable`): such a request is
    never built.
  - `unwritten`: the request built with `null` in place of the message's
    JSON, for the trace of a call not sent because it had none.
  - `invalid`: the first path value its route's template cannot match,
    found when asked for.
  - `unencodable`: over JSON, why its request has no proto3 JSON: a value
    proto3 JSON has no form for, or an `Any` the client's registry cannot
    write. Every call over JSON is checked so, whatever its route holds,
    since a path and a query print values in their JSON forms, but one whose
    method is `withoutRequestCheck` over a typed route with no write limit,
    whose JSON nothing else reads.
  - `tooLarge`: whether its message is over the protocol's write limit,
    measured when asked for.
  - `reader`: how its answer is read, as text or as bytes.
  - `binding`: the binding it takes, when the protocol took one of its
    method's routes, for a trace.
  - `responseBody`: the field of the response its binding's `response_body`
    names, when it names one, which the reader reads the answer as.
  - `timeoutHeader`: the header the protocol carries its timeout in.
  - `base64`: the protocol's base64 writer, for a binary body in a trace.

-}
type alias Plan res =
    { request : () -> Result Proto.Error.Error Request
    , unwritten : () -> Request
    , invalid : () -> Maybe PathError
    , unencodable : () -> Maybe Proto.Error.Error
    , tooLarge : () -> Maybe Size
    , reader : Reader res
    , binding : Maybe Int
    , responseBody : Maybe String
    , timeoutHeader : Maybe ( String, Float -> String )
    , base64 : Maybe (Bytes -> String)
    }


{-| An answer's reading: of text, or of bytes with its metadata.
-}
type Reader res
    = TextReader (Http.Response String -> Result Error res)
    | BytesReader (Http.Response Bytes -> ( Maybe Http.Metadata, Result Error res ))


{-| A call's plan over a client, each part computed only when asked for and
building the route and encoding the request's JSON on its own when it reads
them: for reading an answer, which builds no route and encodes nothing. The
route is built only over a protocol that reads routes, and the response
field an answer is read from is the method's data, not the route's. The
method's JSON codecs, and the reading of a status's details, use the
client's registry.
-}
plan : Client codec -> Call codec req res -> Plan res
plan =
    make False


{-| A call's plan for building or sending its request. Over JSON its
request's JSON (`m.json.encode`, the costly step of a JSON send) is encoded
once, as the plan is made and before any route is built, and every part
that reads it is handed that one value: the check that it has a JSON form,
the route (a route of `FromJson` shape takes it whole), the body and the
write limit. Its route is built once, from that JSON, and only when there is
one.

A method `withoutRequestCheck` skips that write only when nothing but the
check would read the JSON: over a typed route, which holds the body, with no
write limit. Its route is then built from the typed request alone, and its
path and query values are not checked. Anywhere else it is written and
checked as any request is, so a refusal is still reported and no request is
built without the JSON it sends.

-}
toSend : Client codec -> Call codec req res -> Plan res
toSend =
    make True


make : Bool -> Client codec -> Call codec req res -> Plan res
make forSend (Client cl over _ registry) (Call c) =
    let
        (Protocol p functions) =
            over

        (Method m) =
            c.method

        -- Built only for a request: reading an answer needs none of it.
        settings () =
            { baseUrl = cl.baseUrl
            , procedure = "/" ++ m.service ++ "/" ++ m.name
            , idempotency = m.idempotency
            , headers = cl.headers ++ c.headers
            , timeout =
                case Internal.usableTimeout c.timeout of
                    Just ms ->
                        Just ms

                    Nothing ->
                        Internal.usableTimeout cl.timeout
            , withCredentials = cl.withCredentials
            }
    in
    case functions of
        Text wire ->
            let
                routeOf =
                    if p.routed then
                        List.head (List.drop c.binding m.routes)

                    else
                        Nothing

                -- The method's data: reading an answer builds no route.
                responseBody =
                    Maybe.andThen .responseBody routeOf

                routed =
                    case routeOf of
                        Just _ ->
                            True

                        Nothing ->
                            False

                encode () =
                    m.json.encode registry c.message

                routeWith json =
                    Maybe.map
                        (\{ shape } ->
                            case shape of
                                Typed toRoute ->
                                    toRoute c.message

                                FromJson toRoute ->
                                    toRoute c.message json
                        )
                        routeOf

                -- A method that asks not to be checked is not encoded for
                -- a send whose JSON nothing else reads: over a typed route,
                -- which holds the body, under no write limit. Wherever the
                -- JSON is read it is encoded and checked, flag or not.
                unchecked =
                    not m.checkBeforeRoute
                        && (case ( p.options.writeMaxBytes, Maybe.map .shape routeOf ) of
                                ( Nothing, Just (Typed _) ) ->
                                    True

                                _ ->
                                    False
                           )

                -- For a send, the JSON is encoded here, in the branch
                -- taken, and the route built from it once; else each part
                -- encodes and builds when it is asked. An unchecked send's
                -- `Ok null` is read by nothing: its typed route is built
                -- from the request alone, and holds the body.
                ( encoded, route ) =
                    if forSend then
                        let
                            once =
                                if unchecked then
                                    Ok Json.Encode.null

                                else
                                    encode ()

                            onceRouted =
                                Result.map routeWith once
                        in
                        ( \() -> once, \() -> onceRouted )

                    else
                        ( encode, \() -> Result.map routeWith (encode ()) )

                build json maybeRoute =
                    wire.build p.options (settings ()) maybeRoute (\() -> json)
            in
            { request = \() -> Result.map2 build (encoded ()) (route ())
            , unwritten = \() -> build Json.Encode.null (routeWith Json.Encode.null)
            , invalid =
                \() ->
                    case route () of
                        Ok maybeRoute ->
                            Maybe.andThen .invalid maybeRoute

                        Err _ ->
                            Nothing
            , unencodable =
                \() ->
                    case encoded () of
                        Ok _ ->
                            Nothing

                        Err problem ->
                            Just problem
            , tooLarge =
                \() ->
                    case encoded () of
                        Ok json ->
                            wire.tooLarge p.options (\() -> json)

                        Err _ ->
                            Nothing
            , reader =
                TextReader
                    (\answer ->
                        wire.message wire.overRead p.options responseBody answer
                            |> Result.mapError (Status.completeDetails registry)
                            |> Result.andThen
                                (\good ->
                                    readText good.field (m.json.decoder registry) good.text
                                        |> Result.mapError (badText registry good)
                                )
                    )
            , binding = Maybe.map (\_ -> c.binding) routeOf
            , responseBody = responseBody
            , timeoutHeader = wire.timeoutHeader routed
            , base64 = Nothing
            }

        Binary wire ->
            let
                encoder () =
                    m.binary.encode c.message

                request () =
                    wire.build wire.encode wire.base64 p.options (settings ()) (encoder ())
            in
            { request = \() -> Ok (request ())
            , unwritten = request
            , invalid = \() -> Nothing
            , unencodable = \() -> Nothing
            , tooLarge = \() -> wire.tooLarge wire.encodedWidth p.options encoder
            , reader =
                BytesReader
                    (\answer ->
                        let
                            ( metadata, read ) =
                                wire.message (wire.overRead wire.width) p.options (m.service ++ "/" ++ m.name) answer
                        in
                        ( metadata
                        , Result.mapError (Status.completeDetails registry) read
                            |> Result.andThen
                                (\message ->
                                    case m.binary.decode message.bytes of
                                        Ok value ->
                                            Ok value

                                        Err problem ->
                                            Err (message.bad (Proto.Error.BadBinary problem))
                                )
                        )
                    )
            , binding = Nothing
            , responseBody = Nothing
            , timeoutHeader = wire.timeoutHeader
            , base64 = Just wire.base64
            }


{-| The response read from an answer's text, as the field `responseBody`
names when it names one. The response decoder's error comes back as it is, not
as text inside another decoder's failure, so a registry miss in it can still be
found.
-}
readText : Maybe String -> Decoder res -> String -> Result Json.Decode.Error res
readText responseBody decoder text =
    case responseBody of
        Nothing ->
            Json.Decode.decodeString decoder text

        Just key ->
            Json.Decode.decodeString Json.Decode.value text
                |> Result.andThen (\value -> Json.Decode.decodeValue decoder (Json.Encode.object [ ( key, value ) ]))


{-| The error a successful text answer stands for when the response's
decoder does not read it, keeping the answer: its body's problem, an `Any` of
a type the registry lacks named as `UnregisteredType`.
-}
badText : Registry -> GoodText -> Json.Decode.Error -> Error
badText registry good problem =
    Error.badBody (Status.bodyProblem registry problem) (Status.answerOf good.metadata good.raw)


{-| The request a plan sends, or why it is not sent: every check
[`refused`](#refused) makes, on the request the plan builds.
-}
checked : String -> Plan res -> Result Error Request
checked baseUrl p =
    case beforeBuilding baseUrl p of
        Just error ->
            Err error

        Nothing ->
            case p.request () of
                Ok sent ->
                    case afterBuilding p sent of
                        Just error ->
                            Err error

                        Nothing ->
                            Ok sent

                Err problem ->
                    Err (unwritable problem)


{-| Why `sent`, the plan's request or one an application rewrote, must not
reach elm/http: a base URL holding a query or a fragment; a request with no
proto3 JSON, holding a value proto3 JSON has no form for or an `Any` the
registry in use cannot write; a path value its variable's template cannot
match, which no server can route to the method; a header a browser
refuses, on which XHR's `setRequestHeader` throws outside elm/http's
handler and stops the program for good; or a request message over the
protocol's write limit. The path values and the message are the call's,
whatever a rewritten request carries.
-}
refused : String -> Plan res -> Request -> Maybe Error
refused baseUrl p sent =
    case beforeBuilding baseUrl p of
        Just error ->
            Just error

        Nothing ->
            afterBuilding p sent


{-| The checks of the call itself, made before its request is built.
-}
beforeBuilding : String -> Plan res -> Maybe Error
beforeBuilding baseUrl p =
    if Internal.badBaseUrl baseUrl then
        Just (Error.badCall Code.Internal "bad URL: the base URL holds a query or a fragment")

    else
        case ( p.unencodable (), p.invalid () ) of
            ( Just problem, _ ) ->
                Just (unwritable problem)

            ( Nothing, Just path ) ->
                Just (Error.badCall Code.InvalidArgument ("path field " ++ Json.Encode.encode 0 (Json.Encode.string path.field) ++ " does not match " ++ path.template))

            ( Nothing, Nothing ) ->
                Nothing


{-| The checks of the request sent.
-}
afterBuilding : Plan res -> Request -> Maybe Error
afterBuilding p sent =
    case Internal.invalidHeader sent.headers of
        Just name ->
            Just (Error.badCall Code.Internal ("invalid header " ++ Json.Encode.encode 0 (Json.Encode.string name)))

        Nothing ->
            p.tooLarge () |> Maybe.map (Internal.writeTooLargeText >> Error.badCall Code.ResourceExhausted)


{-| The error of a request with no proto3 JSON: a value it holds has no JSON
form, or an `Any` it holds cannot be written.
-}
unwritable : Proto.Error.Error -> Error
unwritable problem =
    case problem of
        Proto.Error.BadValue value ->
            Error.badValue value

        _ ->
            Error.badAny problem


{-| The request an attempt sends with `left` milliseconds of a retry deadline
to go: `sent` with its timeout bounded by them, and the protocol's timeout
header saying so in place of any it had. A request whose timeout is already
within the budget, or sent without a deadline, is `sent` as it is.
-}
withBudget : Plan res -> Maybe Float -> Request -> Request
withBudget p left sent =
    let
        timeout =
            Internal.usableTimeout sent.timeout
    in
    case Retry.attemptTimeout left timeout of
        Just ms ->
            if timeout == Just ms then
                sent

            else
                { sent
                    | timeout = Just ms
                    , headers =
                        case p.timeoutHeader of
                            Just ( name, format ) ->
                                List.filter (\( key, _ ) -> String.toLower key /= String.toLower name) sent.headers
                                    ++ [ ( name, format ms ) ]

                            Nothing ->
                                sent.headers
                }

        Nothing ->
            sent
