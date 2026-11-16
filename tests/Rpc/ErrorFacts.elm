module Rpc.ErrorFacts exposing (Facts, facts)

{-| What a test reads of an `Rpc.Error`: every accessor but the answer's
headers and body and the details, which a test reads itself where it cares.
-}

import Rpc.Code exposing (Code)
import Rpc.Error exposing (Cause, Error, Source)


type alias Facts =
    { code : Code
    , message : String
    , cause : Maybe Cause
    , source : Maybe Source
    , httpStatus : Maybe Int
    }


facts : Error -> Facts
facts error =
    { code = Rpc.Error.code error
    , message = Rpc.Error.message error
    , cause = Rpc.Error.cause error
    , source = Rpc.Error.source error
    , httpStatus = Rpc.Error.httpStatus error
    }
