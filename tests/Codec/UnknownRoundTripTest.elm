module Codec.UnknownRoundTripTest exposing (suite)

{-| `Codec.UnknownRoundTrip` on every sample's binary.
-}

import Codec.UnknownRoundTrip
import Generated.Codec.Codecs
import Generated.Codec.Data
import Test exposing (Test)


suite : Test
suite =
    Codec.UnknownRoundTrip.suite Generated.Codec.Codecs.olderKeep Generated.Codec.Data.samples
