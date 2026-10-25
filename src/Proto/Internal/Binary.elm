module Proto.Internal.Binary exposing (Decoder(..), run)

{-| The binary decoder type, defined here so that `Proto.Message` can run a
decoder without importing `Proto.Binary`, which imports it through
`Proto.Json` and `Proto.Any`.
-}

import Bytes exposing (Bytes)
import Bytes.Decode


{-| A message decoder, given the number of bytes the message occupies.
-}
type Decoder a
    = Decoder (Int -> Bytes.Decode.Decoder a)


{-| A whole input decoded as one message.
-}
run : Decoder a -> Bytes -> Maybe a
run (Decoder decoder) input =
    Bytes.Decode.decode (decoder (Bytes.width input)) input
