module Rpc.Body exposing (Body, none, text, toText)

{-| The body of an [`Rpc.Request`](Rpc#Request): none, or the request's
JSON as text, sent as `application/json`.

    Rpc.Body.toText request.body == Just "{\"name\":\"notes/42\"}"

@docs Body, none, text, toText

-}

import Rpc.Internal.Body as Internal


{-| A request body. Its constructors are private (shown as
`Rpc.Internal.Body.Body`, which this module names), so that a body of bytes
can be added without breaking code that reads one.
-}
type alias Body =
    Internal.Body


{-| No body, as a GET has.
-}
none : Body
none =
    Internal.Empty


{-| A body of text, sent as `application/json`.
-}
text : String -> Body
text =
    Internal.Text


{-| The body's text, or `Nothing` when there is none.
-}
toText : Body -> Maybe String
toText body =
    case body of
        Internal.Empty ->
            Nothing

        Internal.Text content ->
            Just content
