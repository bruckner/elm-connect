module Rpc.Body exposing (Body, none, text, toText)

{-| The body of an [`Rpc.Request`](Rpc#Request): none, or the request's
JSON as text, sent as `application/json`.

    Rpc.Body.toText request.body == Just "{\"name\":\"notes/42\"}"

@docs Body, none, text, toText

-}


{-| A request body. It is opaque: make one with [`none`](#none) or
[`text`](#text) and read it with [`toText`](#toText).
-}
type Body
    = None
    | Text String


{-| No body, as a GET has.
-}
none : Body
none =
    None


{-| A body of text, sent as `application/json`.
-}
text : String -> Body
text =
    Text


{-| The body's text, or `Nothing` when there is none.
-}
toText : Body -> Maybe String
toText body =
    case body of
        None ->
            Nothing

        Text content ->
            Just content
