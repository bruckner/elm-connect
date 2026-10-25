module Live.OneCodec exposing (table)

{-| The dispatch table of methods with one codec of the two, which only the
runner built against bindings generated with `codec=both` has
(`both/src/Live/OneCodec.elm`); this build, against JSON-only bindings, has
none.
-}

import Live.Call exposing (Entry)


table : List ( ( String, String ), Entry msg )
table =
    []
