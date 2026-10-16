module Proto.Internal.Descriptor exposing
    ( EnumDescriptor(..)
    , EnumValue(..)
    , Field(..)
    , MessageDescriptor(..)
    , MethodDescriptor(..)
    )

{-| The descriptor types with their constructors, defined here so that both
`Proto.Descriptor`, which builds them, and the modules that read them
(`Proto.MessageDescriptor`, `Proto.Field` and the rest) can see inside, and
application code cannot.

The unions a descriptor holds (`Cardinality`, `Kind`, `Behavior`,
`Idempotency`) are `Proto.Descriptor`'s, whose constructors are public. This
module cannot import them, since `Proto.Descriptor` imports it, so the types
that hold them take them as parameters, and `Proto.Descriptor`'s aliases
fill them in.

-}

import Proto.Internal.Binding exposing (Binding)


type MessageDescriptor field
    = MessageDescriptor
        { typeName : String
        , fields : List field
        , oneofs : List String
        }


type Field cardinality kind behavior
    = Field
        { name : String
        , jsonName : String
        , number : Int
        , cardinality : cardinality
        , kind : kind
        , oneof : Maybe String
        , behavior : List behavior
        , deprecated : Bool
        }


type EnumDescriptor
    = EnumDescriptor
        { typeName : String
        , values : List EnumValue
        }


type EnumValue
    = EnumValue
        { name : String
        , number : Int
        , deprecated : Bool
        }


type MethodDescriptor idempotency
    = MethodDescriptor
        { service : String
        , name : String
        , idempotency : idempotency
        , input : String
        , output : String
        , bindings : List Binding
        }
