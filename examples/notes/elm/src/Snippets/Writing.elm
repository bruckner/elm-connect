module Snippets.Writing exposing (Event, encodeEvent)

{-| docs/calling.md's "Writing JSON yourself" and `Proto.Json.Encode`'s
"Messages written by hand": the encoder of a message written by hand, with
one field that cannot be refused and one that can.
-}

-- region writing

import Json.Encode
import Proto.Error
import Proto.Json.Encode
import Time


type alias Event =
    { title : String, at : Maybe Time.Posix }


encodeEvent : Event -> Proto.Json.Encode.Encoder Proto.Error.Error
encodeEvent event =
    Proto.Json.Encode.object
        [ Proto.Json.Encode.plainFields
            [ ( "title", Just (Json.Encode.string event.title) ) ]
        , Proto.Json.Encode.checkedFields
            [ ( "at", Proto.Json.Encode.optional Proto.Json.Encode.timestamp event.at ) ]
        ]



-- endregion writing
