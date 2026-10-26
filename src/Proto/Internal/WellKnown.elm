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
    , nullValue
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

import Proto.Enum as Enum
import Proto.EnumValue as EnumValue
import Proto.Field as Field exposing (Cardinality(..), Kind(..), Scalar(..))
import Proto.Message as Message


messages : List Message.Descriptor
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


enums : List Enum.Descriptor
enums =
    [ nullValue ]


nullValue : Enum.Descriptor
nullValue =
    Enum.descriptor "google.protobuf.NullValue" [ EnumValue.descriptor "NULL_VALUE" 0 ]


member : String -> String -> Int -> Kind -> Field.Descriptor
member name jsonName number kind =
    Field.descriptor name jsonName number CardinalitySingular kind |> Field.inOneof "kind"


secondsAndNanos : String -> Message.Descriptor
secondsAndNanos typeName =
    Message.descriptor typeName
        [ Field.descriptor "seconds" "seconds" 1 CardinalitySingular (KindScalar ScalarInt64)
        , Field.descriptor "nanos" "nanos" 2 CardinalitySingular (KindScalar ScalarInt32)
        ]


timestamp : Message.Descriptor
timestamp =
    secondsAndNanos "google.protobuf.Timestamp"


duration : Message.Descriptor
duration =
    secondsAndNanos "google.protobuf.Duration"


any : Message.Descriptor
any =
    Message.descriptor "google.protobuf.Any"
        [ Field.descriptor "type_url" "typeUrl" 1 CardinalitySingular (KindScalar ScalarString)
        , Field.descriptor "value" "value" 2 CardinalitySingular (KindScalar ScalarBytes)
        ]


fieldMask : Message.Descriptor
fieldMask =
    Message.descriptor "google.protobuf.FieldMask" [ Field.descriptor "paths" "paths" 1 CardinalityRepeated (KindScalar ScalarString) ]


empty : Message.Descriptor
empty =
    Message.descriptor "google.protobuf.Empty" []


struct : Message.Descriptor
struct =
    Message.descriptor "google.protobuf.Struct" [ Field.descriptor "fields" "fields" 1 (CardinalityMap ScalarString) (KindMessage "google.protobuf.Value") ]


value : Message.Descriptor
value =
    Message.descriptor "google.protobuf.Value"
        [ member "null_value" "nullValue" 1 (KindEnum nullValue)
        , member "number_value" "numberValue" 2 (KindScalar ScalarDouble)
        , member "string_value" "stringValue" 3 (KindScalar ScalarString)
        , member "bool_value" "boolValue" 4 (KindScalar ScalarBool)
        , member "struct_value" "structValue" 5 (KindMessage "google.protobuf.Struct")
        , member "list_value" "listValue" 6 (KindMessage "google.protobuf.ListValue")
        ]


listValue : Message.Descriptor
listValue =
    Message.descriptor "google.protobuf.ListValue" [ Field.descriptor "values" "values" 1 CardinalityRepeated (KindMessage "google.protobuf.Value") ]


wrapper : String -> Scalar -> Message.Descriptor
wrapper name scalar =
    Message.descriptor ("google.protobuf." ++ name) [ Field.descriptor "value" "value" 1 CardinalitySingular (KindScalar scalar) ]


doubleValue : Message.Descriptor
doubleValue =
    wrapper "DoubleValue" ScalarDouble


floatValue : Message.Descriptor
floatValue =
    wrapper "FloatValue" ScalarFloat


int64Value : Message.Descriptor
int64Value =
    wrapper "Int64Value" ScalarInt64


uint64Value : Message.Descriptor
uint64Value =
    wrapper "UInt64Value" ScalarUint64


int32Value : Message.Descriptor
int32Value =
    wrapper "Int32Value" ScalarInt32


uint32Value : Message.Descriptor
uint32Value =
    wrapper "UInt32Value" ScalarUint32


boolValue : Message.Descriptor
boolValue =
    wrapper "BoolValue" ScalarBool


stringValue : Message.Descriptor
stringValue =
    wrapper "StringValue" ScalarString


bytesValue : Message.Descriptor
bytesValue =
    wrapper "BytesValue" ScalarBytes
