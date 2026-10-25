module Rpc.Stream.Element exposing (view)

{-| A server stream as a view: `<connect-stream>` (spike/element/connect-stream.js)
streams while it is rendered with a command, and reports each event as the
same JSON the port protocol carries.

    Rpc.Stream.Element.view
        { command = Rpc.Stream.open config { id = id, call = call } |> Result.toMaybe
        , onEvent = Introducing << Session.incoming
        }

Render it under `Html.Keyed` when it shares a parent with nodes that come and
go, so that Elm keeps the same element instead of replacing it.

-}

import Html exposing (Html)
import Html.Attributes as Attributes
import Html.Events as Events
import Json.Decode as Decode
import Json.Encode as Encode


{-| The element: `command` is a value from `Rpc.Stream.open`, or `Nothing`
for no stream; `onEvent` receives each event.
-}
view : { command : Maybe Encode.Value, onEvent : Decode.Value -> msg } -> Html msg
view { command, onEvent } =
    Html.node "connect-stream"
        [ Attributes.property "open" (Maybe.withDefault Encode.null command)
        , Events.on "stream" (Decode.map onEvent (Decode.field "detail" Decode.value))
        ]
        []
