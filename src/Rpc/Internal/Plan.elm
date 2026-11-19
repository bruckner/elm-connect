module Rpc.Internal.Plan exposing (Plan, Reader(..), plan, refused, toSend, withBudget)

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
import Proto.Internal.Method exposing (Method(..), RouteOf)
import Proto.Internal.Registry
import Proto.Registry exposing (Registry)
import Proto.Route exposing (PathError, Route)
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

  - `request`: the request it sends, built when asked for.
  - `invalid`: the first path value its route's template cannot match,
    found when asked for.
  - `unencodable`: over JSON, why its request, holding an `Any` the
    client's registry cannot write, cannot be sent: its route's failure, or
    over no route its JSON's, found when asked for.
  - `tooLarge`: whether its message is over the protocol's write limit,
    measured when asked for.
  - `reader`: how its answer is read, as text or as bytes.
  - `binding`: the binding it takes, when the protocol took one of its
    method's routes, for a trace.
  - `responseBody`: the field of the response its route's `response_body`
    names, when it names one, which the reader reads the answer as.
  - `timeoutHeader`: the header the protocol carries its timeout in.
  - `base64`: the protocol's base64 writer, for a binary body in a trace.

-}
type alias Plan res =
    { request : () -> Request
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
encoding the request's JSON on its own when it reads it: for reading an
answer, which builds no route and encodes nothing, or building the request
alone. The route is built only over a protocol that reads routes, and the
response field its answer is read from is the method's, not the route's. The
method's JSON codecs, the routes, and the reading of a status's details use
the client's registry.
-}
plan : Client codec -> Call codec req res -> Plan res
plan =
    make False


{-| A call's plan for a send, of the request it builds or of one given in
its place (`Rpc.taskFromRequest`). Its route is built once, as the plan is
made, and its request's JSON (`m.json.encode`, the costly step of a JSON
send) is encoded once when the body or the write limit reads it, and every
part that reads either is handed that one value.
-}
toSend : Client codec -> Call codec req res -> Plan res
toSend =
    make True


make : Bool -> Client codec -> Call codec req res -> Plan res
make forSend (Client cl) (Call c) =
    let
        (Protocol p) =
            cl.protocol

        (Method m) =
            c.method

        registry =
            cl.registry

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
    case p.wire of
        Text wire ->
            let
                routeOf =
                    if wire.routed then
                        List.head (List.drop c.binding m.routes)

                    else
                        Nothing

                routed =
                    case routeOf of
                        Just _ ->
                            True

                        Nothing ->
                            False

                -- A route holds its body; with none, the JSON is the body.
                -- The write limit reads the JSON whenever there is one.
                readsJson =
                    case p.options.writeMaxBytes of
                        Just _ ->
                            True

                        Nothing ->
                            not routed

                encode () =
                    m.json.encode registry c.message

                build () =
                    Maybe.map (built registry c.message) routeOf

                -- Built here, in the branch taken, for a send; else each
                -- part builds when it is asked.
                ( encoded, made ) =
                    if forSend then
                        let
                            onceMade =
                                build ()
                        in
                        if readsJson then
                            let
                                once =
                                    encode ()
                            in
                            ( \() -> once, \() -> onceMade )

                        else
                            ( encode, \() -> onceMade )

                    else
                        ( encode, build )

                route () =
                    case made () of
                        Just (Ok r) ->
                            Just r

                        Just (Err ( _, shown )) ->
                            shown

                        Nothing ->
                            Nothing

                json () =
                    Result.withDefault Json.Encode.null (encoded ())
            in
            { request = \() -> wire.build p.options (settings ()) (route ()) json
            , invalid = \() -> Maybe.andThen .invalid (route ())
            , unencodable =
                \() ->
                    case made () of
                        Just (Ok _) ->
                            Nothing

                        Just (Err ( problem, _ )) ->
                            Just problem

                        Nothing ->
                            case encoded () of
                                Ok _ ->
                                    Nothing

                                Err problem ->
                                    Just problem
            , tooLarge = \() -> wire.tooLarge p.options json
            , reader =
                TextReader
                    (\answer ->
                        wire.message wire.overRead p.options (Maybe.andThen .responseBody routeOf) answer
                            |> Result.mapError (Status.completeDetails registry)
                            |> Result.andThen
                                (\good ->
                                    readText good.field (m.json.decoder registry) good.text
                                        |> Result.mapError (badText registry good)
                                )
                    )
            , binding = Maybe.map (\_ -> c.binding) routeOf
            , responseBody = Maybe.andThen .responseBody routeOf
            , timeoutHeader = wire.timeoutHeader routed
            , base64 = Nothing
            }

        Binary wire ->
            let
                encoder () =
                    m.binary.encode c.message
            in
            { request = \() -> wire.build wire.base64 p.options (settings ()) (encoder ())
            , invalid = \() -> Nothing
            , unencodable = \() -> Nothing
            , tooLarge = \() -> wire.tooLarge wire.width p.options encoder
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


{-| A binding's route of a request, or why it cannot be built and the route
the request shows in its place: built again through a registry that writes
each `Any` it cannot as its type alone, so that the request keeps its verb,
path and query. A route that fails whatever the registry, which only one
written by hand can, shows none: the request is then the implicit route's.
Neither is sent: sending refuses the call for the first failure.
-}
built : Registry -> req -> RouteOf req -> Result ( Proto.Error.Error, Maybe Route ) Route
built registry message routeOf =
    case routeOf.build registry message of
        Ok route ->
            Ok route

        Err problem ->
            Err ( problem, Result.toMaybe (routeOf.build (Proto.Internal.Registry.standIn registry) message) )


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


{-| Why `sent`, the plan's request or one an application rewrote, must not
reach elm/http: a base URL holding a query or a fragment; a request holding
an `Any` the registry in use cannot write as JSON; a path value its
variable's template cannot match, which no server can route to the method; a
header a browser refuses, on which XHR's `setRequestHeader` throws outside
elm/http's handler and stops the program for good; or a request message over
the protocol's write limit. The path values and the message are the call's,
whatever a rewritten request carries.
-}
refused : String -> Plan res -> Request -> Maybe Error
refused baseUrl p sent =
    if Internal.badBaseUrl baseUrl then
        Just (Error.badCall Code.Internal "bad URL: the base URL holds a query or a fragment")

    else
        case ( p.unencodable (), p.invalid (), Internal.invalidHeader sent.headers ) of
            ( Just problem, _, _ ) ->
                Just (Error.badAny problem)

            ( Nothing, Just path, _ ) ->
                Just (Error.badCall Code.InvalidArgument ("path field " ++ Json.Encode.encode 0 (Json.Encode.string path.field) ++ " does not match " ++ path.template))

            ( Nothing, Nothing, Just name ) ->
                Just (Error.badCall Code.Internal ("invalid header " ++ Json.Encode.encode 0 (Json.Encode.string name)))

            ( Nothing, Nothing, Nothing ) ->
                p.tooLarge () |> Maybe.map (Internal.writeTooLargeText >> Error.badCall Code.ResourceExhausted)


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
