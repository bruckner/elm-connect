module ShapeBuild exposing (Client, Problem(..), Settings, build, quickStart, withTimeout)

{-| Design question 1, shape 2 (scratch, not the runtime): one fallible
constructor takes everything checkable as a record and checks it all at
once, giving every problem; the result is a client that holds no bad value,
and only the modifiers that cannot make one (timeout, credentials, retry)
stay as modifiers.
-}

import Rpc
import Rpc.Protocol exposing (Protocol)


type Problem
    = QueryOrFragment String
    | NotAToken String
    | UnsendableValue String
    | BelowOne String Int


type alias Settings =
    { baseUrl : String
    , headers : List ( String, String )
    , readMaxBytes : Maybe Int
    , writeMaxBytes : Maybe Int
    }


type Client codec
    = Client { protocol : Protocol codec, settings : Settings, timeout : Maybe Float }


build : Protocol codec -> Settings -> Result (List Problem) (Client codec)
build protocol settings =
    let
        problems =
            (if String.contains "?" settings.baseUrl || String.contains "#" settings.baseUrl then
                [ QueryOrFragment settings.baseUrl ]

             else
                []
            )
                ++ List.filterMap
                    (\( name, value ) ->
                        if String.isEmpty name then
                            Just (NotAToken name)

                        else if String.any (\c -> Char.toCode c > 0xFF) value then
                            Just (UnsendableValue name)

                        else
                            Nothing
                    )
                    settings.headers
                ++ List.filterMap identity
                    [ settings.readMaxBytes |> Maybe.andThen (\n -> if n < 1 then Just (BelowOne "readMaxBytes" n) else Nothing)
                    , settings.writeMaxBytes |> Maybe.andThen (\n -> if n < 1 then Just (BelowOne "writeMaxBytes" n) else Nothing)
                    ]
    in
    if List.isEmpty problems then
        Ok (Client { protocol = protocol, settings = settings, timeout = Nothing })

    else
        Err problems


withTimeout : Float -> Client codec -> Client codec
withTimeout ms (Client c) =
    Client { c | timeout = Just ms }


quickStart : Result (List Problem) (Client Rpc.Json)
quickStart =
    build Rpc.Protocol.connect { baseUrl = "https://demo.connectrpc.com", headers = [], readMaxBytes = Nothing, writeMaxBytes = Nothing }
