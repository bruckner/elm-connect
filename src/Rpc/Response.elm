module Rpc.Response exposing (Response)

{-| An HTTP answer as data: what an [`Rpc.Error`](Rpc#Error) keeps of the
answer when the server sent one, so you can read its status, headers and
body after a call fails.

@docs Response

-}

import Dict exposing (Dict)
import Rpc.Body exposing (Body)


{-| An answer as it arrived: the URL it came from (after any redirect), its
HTTP status and status text, its headers as elm/http gives them, and its body,
an [`Rpc.Body`](Rpc-Body) read with `Rpc.Body.toText`. The fields are
elm/http's `Http.Metadata` and the body; the record's fields are fixed.
-}
type alias Response =
    { url : String
    , statusCode : Int
    , statusText : String
    , headers : Dict String String
    , body : Body
    }
