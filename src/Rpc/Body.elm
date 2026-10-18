module Rpc.Body exposing (Body, none, text, toText)

{-| The body of an [`Rpc.Request`](Rpc#Request) or an
[`Rpc.Response`](Rpc#Response): none, or text, a request's JSON sent as
`application/json` or an answer's body as it arrived.

    Rpc.Body.toText request.body == Just "{\"name\":\"notes/42\"}"

@docs Body, none, text, toText

-}


{-| A body. It is opaque: make one with [`none`](#none) or
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


{-| A body of text: a request's is sent as `application/json`, an answer's is
what arrived, empty when the server sent none.
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
