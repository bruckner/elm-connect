module Rpc.Response exposing (Response)

{-| An HTTP answer as data: what an [`Rpc.Error`](Rpc#Error) from the server
keeps of it.

@docs Response

-}

import Dict exposing (Dict)


{-| An answer as it arrived: the URL it came from (after any redirect), its
HTTP status and status text, its headers as elm/http gives them, and its body.
The fields are elm/http's `Http.Metadata` and the body; the record's fields
are fixed.
-}
type alias Response =
    { url : String
    , statusCode : Int
    , statusText : String
    , headers : Dict String String
    , body : String
    }
