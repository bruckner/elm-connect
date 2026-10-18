module Snippets.Details exposing (violations)

{-| The README's error details, read with the `Google.Rpc` this example
generates from googleapis' `google/rpc/error_details.proto`.
-}

-- region details

import Google.Rpc
import Rpc
import Rpc.Error


violations : Rpc.Error -> List String
violations error =
    Rpc.Error.details Google.Rpc.messageBadRequest error
        |> List.concatMap .fieldViolations
        |> List.map .description



-- endregion details
