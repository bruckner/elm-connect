module Rpc.Internal.Error exposing
    ( Cause(..)
    , Error(..)
    , Fault(..)
    , Fields
    , Size
    , Source(..)
    , Status
    , badAny
    , badBody
    , badEnvelope
    , badHeader
    , badPathValue
    , badUrl
    , networkError
    , requestTooLarge
    , responseTooLarge
    , stated
    , statusText
    , timeout
    , unstated
    )

{-| What a failed call holds. Not exposed. `Rpc.Error` aliases the type and
reads it; the protocol modules build one with the functions here, each of
which gives the code the runtime states for its kind.

Every error has a cause or a response, or both: a server's failure has a
response and no cause, an answer that could not be used has both, and a
call that failed before an answer has a cause alone. The functions here and
`Rpc.Error`'s builders keep it so.

`fault` holds what the message is written from. It keeps the facts the
runtime found (the URL, the header's name, the sizes, the `Proto.Error`), so
that the message is written only when it is read.

-}

import Http
import Proto.Any exposing (Any)
import Proto.Error
import Rpc.Body
import Rpc.Code as Code exposing (Code)
import Rpc.Response exposing (Response)


{-| A failed call.
-}
type Error
    = Error Fields


{-| An error's facts: its code, why the client produced it (`Nothing` when the
server answered with a failure), where the server stated its status, its
details, the answer kept, and what its message is written from.
-}
type alias Fields =
    { code : Code
    , cause : Maybe Cause
    , source : Maybe Source
    , details : List (Result Proto.Error.Error Any)
    , response : Maybe Response
    , fault : Fault
    }


{-| Why the client produced an error; `Rpc.Error.Cause` reads it.
-}
type Cause
    = BadCall
    | NetworkError
    | Timeout
    | BadResponse


{-| Where a server stated a status; `Rpc.Error.Source` reads it.
-}
type Source
    = ConnectBody
    | StatusBody
    | GrpcHeaders
    | GrpcTrailers
    | ConnectEndStream


{-| What an error's message is written from: a text as it stands (the
server's message, the status text, a builder's), or the facts of a failure
the client found.
-}
type Fault
    = Said String
    | BadUrl String
    | BadHeader String
    | BadPathValue { field : String, template : String }
    | RequestTooLarge Size
    | ResponseTooLarge Size
    | BadAny Proto.Error.Error
    | BadBody Proto.Error.Error
    | BadEnvelope String


{-| A status a server stated.
-}
type alias Status =
    { code : Code
    , message : String
    , details : List (Result Proto.Error.Error Any)
    , source : Source
    }


{-| A message's size in bytes, over its limit.
-}
type alias Size =
    { limit : Int, size : Int }


{-| A failure whose status the server stated, with the answer it came in.
-}
stated : Status -> Response -> Error
stated status answer =
    Error
        { code = status.code
        , cause = Nothing
        , source = Just status.source
        , details = status.details
        , response = Just answer
        , fault = Said status.message
        }


{-| A failure answer that states no status: its code is the HTTP status's,
its message the status text.
-}
unstated : Response -> Error
unstated answer =
    Error
        { code = Code.fromHttpStatus answer.statusCode
        , cause = Nothing
        , source = Nothing
        , details = []
        , response = Just answer
        , fault = Said (statusText answer)
        }


{-| An answer's status text, or `HTTP <status>` when it has none.
-}
statusText : Response -> String
statusText answer =
    if String.isEmpty answer.statusText then
        "HTTP " ++ String.fromInt answer.statusCode

    else
        answer.statusText


local : Cause -> Code -> Fault -> Maybe Response -> Error
local cause code fault answer =
    Error
        { code = code
        , cause = Just cause
        , source = Nothing
        , details = []
        , response = answer
        , fault = fault
        }


timeout : Error
timeout =
    local Timeout Code.DeadlineExceeded (Said "timeout") Nothing


networkError : Error
networkError =
    local NetworkError Code.Unavailable (Said "network error") Nothing


badUrl : String -> Error
badUrl url =
    local BadCall Code.Internal (BadUrl url) Nothing


badHeader : String -> Error
badHeader name =
    local BadCall Code.Internal (BadHeader name) Nothing


badPathValue : { field : String, template : String } -> Error
badPathValue path =
    local BadCall Code.InvalidArgument (BadPathValue path) Nothing


badAny : Proto.Error.Error -> Error
badAny problem =
    local BadCall Code.Internal (BadAny problem) Nothing


requestTooLarge : Size -> Error
requestTooLarge size =
    local BadCall Code.ResourceExhausted (RequestTooLarge size) Nothing


{-| A successful answer over the read limit: its status and headers are kept,
without its body, which was dropped unread.
-}
responseTooLarge : Size -> Http.Metadata -> Error
responseTooLarge size metadata =
    local BadResponse
        Code.ResourceExhausted
        (ResponseTooLarge size)
        (Just
            { url = metadata.url
            , statusCode = metadata.statusCode
            , statusText = metadata.statusText
            , headers = metadata.headers
            , body = Rpc.Body.none
            }
        )


{-| A successful answer whose body is not the response message.
-}
badBody : Proto.Error.Error -> Response -> Error
badBody problem answer =
    local BadResponse Code.Internal (BadBody problem) (Just answer)


{-| A successful answer whose framing, content type or status is malformed,
described, with the code the runtime gives it.
-}
badEnvelope : Code -> String -> Response -> Error
badEnvelope code problem answer =
    local BadResponse code (BadEnvelope problem) (Just answer)
