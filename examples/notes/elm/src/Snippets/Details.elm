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
    case error of
        Rpc.Error.RpcStatus status _ ->
            status.details
                |> List.filterMap Result.toMaybe
                |> List.filterMap (Proto.Any.unpack Proto.ErrorDetails.badRequest)
                |> List.concatMap .fieldViolations
                |> List.map .description

        _ ->
            []



-- endregion details
