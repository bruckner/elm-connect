module ShapeTyped exposing
    ( BaseUrl, baseUrl, Header, header, Limit, limit, Problem(..)
    , Client, client, withHeaders, withReadMaxBytes
    , quickStart, fromSettings, perCall
    )

{-| Design question 1, shape 1 (scratch, not the runtime): the values a
client is built from are typed, each with a validating constructor, so a
`Client` cannot hold a bad base URL, a header a browser refuses or a limit
below 1. `client` itself cannot fail; what can fail is turning text into a
`BaseUrl` or a `Header`.
-}

import Connectrpc.Eliza.V1
import Connectrpc.Eliza.V1.ElizaService as ElizaService
import Rpc
import Rpc.Protocol exposing (Protocol)


type Problem
    = QueryOrFragment String
    | NotAToken String
    | UnsendableValue String
    | BelowOne Int


type BaseUrl
    = BaseUrl String


baseUrl : String -> Result Problem BaseUrl
baseUrl url =
    if String.contains "?" url || String.contains "#" url then
        Err (QueryOrFragment url)

    else
        Ok (BaseUrl url)


type Header
    = Header String String


header : String -> String -> Result Problem Header
header name value =
    if String.isEmpty name || not (String.all (\c -> Char.isAlphaNum c || String.contains (String.fromChar c) "!#$%&'*+-.^_`|~") name) then
        Err (NotAToken name)

    else if not (String.all (\c -> Char.toCode c <= 0xFF && Char.toCode c /= 0 && Char.toCode c /= 10 && Char.toCode c /= 13) value) then
        Err (UnsendableValue name)

    else
        Ok (Header name value)


type Limit
    = Limit Int


limit : Int -> Result Problem Limit
limit n =
    if n < 1 then
        Err (BelowOne n)

    else
        Ok (Limit n)


type Client codec
    = Client { protocol : Protocol codec, baseUrl : BaseUrl, headers : List Header, readMaxBytes : Maybe Limit }


client : Protocol codec -> BaseUrl -> Client codec
client protocol url =
    Client { protocol = protocol, baseUrl = url, headers = [], readMaxBytes = Nothing }


withHeaders : List Header -> Client codec -> Client codec
withHeaders extra (Client c) =
    Client { c | headers = c.headers ++ extra }


withReadMaxBytes : Limit -> Client codec -> Client codec
withReadMaxBytes most (Client c) =
    Client { c | readMaxBytes = Just most }


{-| The quick start: a literal base URL is still text, so the top-level
client is a `Result` the application unwraps where it sends.
-}
quickStart : Result Problem (Client Rpc.Json)
quickStart =
    baseUrl "https://demo.connectrpc.com"
        |> Result.map (client Rpc.Protocol.connect)


{-| A client from settings read at start-up: every problem is found here,
once, in `init`.
-}
fromSettings : { apiUrl : String, token : String } -> Result Problem (Client Rpc.Json)
fromSettings settings =
    Result.map2 (\url auth -> client Rpc.Protocol.connect url |> withHeaders [ auth ])
        (baseUrl settings.apiUrl)
        (header "Authorization" ("Bearer " ++ settings.token))


{-| What stays a run-time failure whatever the client: a call's own headers
(unless `Rpc.Call.withHeaders` takes `Header` too), a path value its
template rejects, a URL the browser refuses, and every answer.
-}
perCall : Rpc.Call Rpc.Json Connectrpc.Eliza.V1.SayRequest Connectrpc.Eliza.V1.SayResponse
perCall =
    ElizaService.say { sentence = "hi" }
