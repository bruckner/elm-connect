module Proto.Internal.Binding exposing
    ( Binding(..)
    , Body(..)
    , Param(..)
    , Rule
    , Segment(..)
    )

{-| The HTTP binding types, with their constructors. `Proto.Http` builds them
and exposes the types alone, so an application builds a binding and cannot
take one apart; `Proto.Method.withBindings` and the interpreter it calls,
`Proto.Internal.Interpret`, match them here to make a request's route.
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
    | Variable (List String) (List Segment) String


type Body
    = NoBody
    | WholeBody
    | BodyField String


type Param
    = Param { name : String, path : List String, zero : Maybe String }
