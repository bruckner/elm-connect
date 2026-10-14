module Proto.Internal.Binding exposing
    ( Binding(..)
    , Body(..)
    , Param(..)
    , Rule
    , Segment(..)
    )

{-| The HTTP binding types, defined here so that `Rpc` can read what
`Proto.Http` exposes only to build.
-}


type Binding
    = Binding Rule


type alias Rule =
    { method : String
    , path : List Segment
    , customVerb : Maybe String
    , body : Body
    , responseBody : Maybe String
    , query : List Param
    }


type Segment
    = Literal String
    | Wildcard
    | DoubleWildcard
    | Variable (List String) (List Segment)


type Body
    = NoBody
    | WholeBody
    | BodyField String


type Param
    = Param { name : String, path : List String, zero : Maybe String }
