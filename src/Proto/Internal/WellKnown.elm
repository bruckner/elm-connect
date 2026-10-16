module Proto.Internal.WellKnown exposing
    ( any
    , boolValue
    , bytesValue
    , doubleValue
    , duration
    , empty
    , enums
    , fieldMask
    , floatValue
    , int32Value
    , int64Value
    , listValue
    , messages
    , stringValue
    , struct
    , timestamp
    , uint32Value
    , uint64Value
    , value
    )

{-| The descriptors of the `google.protobuf` types elm-connect maps, as
`descriptor.proto` and the well-known type files declare them. Here rather than
in `Proto.WellKnown` so that `Proto.Registry` can hold them without depending
on the codecs.
-}

import Proto.Descriptor exposing (Cardinality(..), EnumDescriptor, Field, Kind(..), MessageDescriptor, Scalar(..), field, inOneof, message)


messages : List MessageDescriptor
messages =
    [ any
    , timestamp
    , duration
    , fieldMask
    , empty
    , struct
    , value
    , listValue
    , doubleValue
    , floatValue
    , int64Value
    , uint64Value
    , int32Value
    , uint32Value
    , boolValue
    , stringValue
    , bytesValue
    ]


enums : List EnumDescriptor
enums =
    [ Proto.Descriptor.enum "google.protobuf.NullValue" [ Proto.Descriptor.value "NULL_VALUE" 0 ] ]


member : String -> String -> Int -> Kind -> Field
member name jsonName number kind =
    field name jsonName number Singular kind |> inOneof "kind"


secondsAndNanos : String -> MessageDescriptor
secondsAndNanos typeName =
    message typeName
        [ field "seconds" "seconds" 1 Singular (Scalar Int64)
        , field "nanos" "nanos" 2 Singular (Scalar Int32)
        ]


timestamp : MessageDescriptor
timestamp =
    secondsAndNanos "google.protobuf.Timestamp"


duration : MessageDescriptor
duration =
    secondsAndNanos "google.protobuf.Duration"


any : MessageDescriptor
any =
    message "google.protobuf.Any"
        [ field "type_url" "typeUrl" 1 Singular (Scalar String)
        , field "value" "value" 2 Singular (Scalar Bytes)
        ]


fieldMask : MessageDescriptor
fieldMask =
    message "google.protobuf.FieldMask" [ field "paths" "paths" 1 Repeated (Scalar String) ]


empty : MessageDescriptor
empty =
    message "google.protobuf.Empty" []


struct : MessageDescriptor
struct =
    message "google.protobuf.Struct" [ field "fields" "fields" 1 (Map String) (Message "google.protobuf.Value") ]


value : MessageDescriptor
value =
    message "google.protobuf.Value"
        [ member "null_value" "nullValue" 1 (Enum "google.protobuf.NullValue")
        , member "number_value" "numberValue" 2 (Scalar Double)
        , member "string_value" "stringValue" 3 (Scalar String)
        , member "bool_value" "boolValue" 4 (Scalar Bool)
        , member "struct_value" "structValue" 5 (Message "google.protobuf.Struct")
        , member "list_value" "listValue" 6 (Message "google.protobuf.ListValue")
        ]


listValue : MessageDescriptor
listValue =
    message "google.protobuf.ListValue" [ field "values" "values" 1 Repeated (Message "google.protobuf.Value") ]


wrapper : String -> Scalar -> MessageDescriptor
wrapper name scalar =
    message ("google.protobuf." ++ name) [ field "value" "value" 1 Singular (Scalar scalar) ]


doubleValue : MessageDescriptor
doubleValue =
    wrapper "DoubleValue" Double


floatValue : MessageDescriptor
floatValue =
    wrapper "FloatValue" Float


int64Value : MessageDescriptor
int64Value =
    wrapper "Int64Value" Int64


uint64Value : MessageDescriptor
uint64Value =
    wrapper "UInt64Value" Uint64


int32Value : MessageDescriptor
int32Value =
    wrapper "Int32Value" Int32


uint32Value : MessageDescriptor
uint32Value =
    wrapper "UInt32Value" Uint32


boolValue : MessageDescriptor
boolValue =
    wrapper "BoolValue" Bool


stringValue : MessageDescriptor
stringValue =
    wrapper "StringValue" String


bytesValue : MessageDescriptor
bytesValue =
    wrapper "BytesValue" Bytes
