module Proto.Json.Encoder exposing (Encoder)

{-| The type of a proto3 JSON encoder, on its own so that every module that
takes one can name it. [`Proto.Json`](Proto-Json) names it
[`Proto.Json.Encoder`](Proto-Json#Encoder) and holds everything that builds
one and writes it.

@docs Encoder

-}

import Proto.Internal.Writer as Writer


{-| A proto3 JSON encoder that refuses with `x`: what a generated
`encodeNote : Note -> Proto.Json.Encoder x` gives, written by
[`Proto.Json.encode`](Proto-Json#encode). It is opaque. The package site and
compiler errors may show it as `Proto.Internal.Writer.Encoder`, its name
inside the package.
-}
type alias Encoder x =
    Writer.Encoder x
