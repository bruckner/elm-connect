module Snippets.Details exposing (violations)

{-| docs/descriptors.md's error details, read with the runtime's
`Proto.ErrorDetails`, googleapis' `google/rpc/error_details.proto`.
-}

-- region details

import Proto.Any
import Proto.ErrorDetails
import Rpc
import Rpc.Error


violations : Rpc.Error -> List String
violations error =
    Rpc.Error.details error
        |> List.filterMap Result.toMaybe
        |> List.filterMap (Proto.Any.unpack Proto.ErrorDetails.badRequest)
        |> List.concatMap .fieldViolations
        |> List.map .description



-- endregion details
