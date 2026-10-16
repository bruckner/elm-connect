module Rpc.Internal.Body exposing (Body(..))

{-| A request body. Not exposed; `Rpc.Body.Body` is this type, its constructors
private so that kinds of body can be added without breaking a match.
-}


{-| No body, or text sent as `application/json`.
-}
type Body
    = Empty
    | Text String
