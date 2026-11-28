module Proto.Unknown exposing
    ( Fields, empty
    , Value(..), toList, fromList
    )

{-| The fields of a protobuf binary message that its schema does not know.

Code generated with the option `unknown_fields=keep` gives every message
record a last field, `unknownFields_ : Proto.Unknown.Fields`, so that a
message read from protobuf binary and written back keeps the fields a newer
schema added, and `==` sees them. Without the option the field is not there
and such fields are dropped.

The fields are non-empty only in a message read from protobuf binary
(`Proto.Binary.decode Notes.V1.decodeNoteBinary`, or the answer to a call over
Connect's binary codec or gRPC-Web) that carried a field number its schema does
not declare, or a declared field in a wire type the declaration does not take
(an `int32` sent length-delimited). A message built in Elm holds none until
you put some there.

Proto3 JSON has no place for them: a JSON read gives none, and a JSON write
leaves them out.

Fields of a message the runtime holds as its own type (a `Timestamp`, a
`Struct`, a wrapper such as `google.protobuf.StringValue`) and of a map's
entries are dropped whatever the option says. A packed `google.protobuf.Any`
keeps its payload's bytes as they arrived.


## Building a message

A record literal of a generated message names the field:

    request : Notes.V1.GetNoteRequest
    request =
        { name = "notes/1"
        , unknownFields_ = Proto.Unknown.empty
        }

A record built from the generated default holds none already:

    let
        note =
            Notes.V1.defaultNote
    in
    { note | title = "Groceries" }

@docs Fields, empty


## As data

For a test, or to see what a newer peer sent.

@docs Value, toList, fromList

-}

import Proto.Internal.Unknown as Internal


{-| The unknown fields of one message, by field number, and in the order they
arrived within one number.

A message holding them writes them to protobuf binary after its known fields,
in that order.

Two are `==` when they hold the same fields:

  - fields of different numbers that arrived in another order are equal, as
    they are kept sorted by number;
  - fields of one number that arrived in another order are not, since that
    order is a repeated field's element order to a schema that knows the
    field;
  - a varint is compared as a number, so one written in more bytes than it
    needs is equal to its shortest form;
  - a length-delimited value is compared as its bytes, since the wire does
    not say what it holds: a nested message whose fields arrived in another
    order is not equal, nor is a packed run of numbers to the same numbers
    sent one field each.

The package site and compiler errors may show it as
`Proto.Internal.Unknown.Fields Value`, its definition inside the package.

-}
type alias Fields =
    Internal.Fields Value


{-| No unknown fields: what a message built in Elm or read from proto3 JSON
holds, and what a record literal of a generated message gives
`unknownFields_` unless it means to send some.

A message read from protobuf binary that met none is `==` to `empty` too:

    Expect.equal Proto.Unknown.empty note.unknownFields_

-}
empty : Fields
empty =
    Internal.Fields []


{-| One field's value, as its wire type gives it:

  - `Varint high low`: a varint as two unsigned 32-bit halves, high then low,
    each from 0 to 4294967295; the wire does not say whether it is an `int64`,
    a `sint64` (zigzag), an `int32`, an enum or a `bool`;
  - `Fixed64 high low`: eight bytes, the same two halves;
  - `Fixed32 bits`: four bytes, unsigned, from 0 to 4294967295;
  - `Delimited base64`: a length-delimited value (a `string`, `bytes`, a
    message or a packed run, which the wire does not tell apart) as standard
    base64 with padding.

-}
type Value
    = Varint Int Int
    | Fixed64 Int Int
    | Fixed32 Int
    | Delimited String


{-| Each field with its number, by field number, and in arrival order within
one number: the order a message writes them in.

    Proto.Unknown.toList note.unknownFields_
    --> [ ( 7, Proto.Unknown.Varint 0 1 ), ( 9, Proto.Unknown.Delimited "aGk=" ) ]

-}
toList : Fields -> List ( Int, Value )
toList (Internal.Fields fields) =
    fields


{-| Fields from a list, sorted by field number, keeping the list's order
within one number, as a binary read would hold them.

    Proto.Unknown.fromList [ ( 9, Proto.Unknown.Delimited "aGk=" ), ( 7, Proto.Unknown.Varint 0 1 ) ]
        |> Proto.Unknown.toList
    --> [ ( 7, Proto.Unknown.Varint 0 1 ), ( 9, Proto.Unknown.Delimited "aGk=" ) ]

Nothing is checked: a field number outside 1 to 536870911 or a half outside
0 to 4294967295 is written as given and gives bytes no reader takes, and a
`Delimited` text that is not base64 is written as an empty value.

-}
fromList : List ( Int, Value ) -> Fields
fromList fields =
    Internal.Fields (List.sortBy Tuple.first fields)
