module Proto.Binary exposing
    ( decode, encode, Decoder, map
    , Codec
    , merge, mergeTable, field, fieldInto, repeated, mapEntry, insertBool, skip
    , implicit, optional, present, list, listUnpacked, dict, boolMap
    , double, float
    , int32, sint32, sfixed32, uint32, fixed32
    , int64, sint64, sfixed64, uint64, fixed64
    , int64AsInt, sint64AsInt, sfixed64AsInt, uint64AsInt, fixed64AsInt
    , bool, string, bytes, bytesAsBytes, enum
    , embedded, messageEncoder, messageDecoder
    , timestamp, duration, fieldMask, empty, struct, listValue, value, any, anyWith
    , doubleValue, floatValue, int64Value, int64ValueAsInt, uint64Value, uint64ValueAsInt
    , int32Value, uint32Value, boolValue, stringValue, bytesValue, bytesValueAsBytes
    )

{-| The protobuf binary wire format, over elm/bytes: the helpers generated
binary codecs (`encodeNoteBytes`, `decodeNoteBytes`) are written with.

A message's [`Decoder`](#Decoder) reads it from a whole input with
[`decode`](#decode), or into a value already read, as protobuf merges a
message that arrives twice.

    Proto.Binary.decode Notes.V1.decodeNoteBytes body
    --> Just note

Encoders write fields in field-number order, leave out a field without
presence at its default, and write a map's entries in the order of its
`Dict` (a `bool`-keyed map's `False` entry first), so the same value always
gives the same bytes. Decoders read fields in any order, the last of a
repeated singular field winning and a message field merged into the one
read before it, read a repeated scalar packed or not, and skip a field they
do not know, or one of a wire type its declaration does not take, by its
wire type; a group, a length past the end and a varint longer than ten
bytes fail.

64-bit integers are held as the generated code holds them: a decimal
`String`, exact, or an `Int` (the `AsInt` codecs) that fails to decode
outside ±(2^53 − 1).

@docs decode, encode, Decoder, map


# Codecs

@docs Codec


# Decoding a message

@docs merge, mergeTable, field, fieldInto, repeated, mapEntry, insertBool, skip


# Encoding a message

@docs implicit, optional, present, list, listUnpacked, dict, boolMap


# Scalars

@docs double, float
@docs int32, sint32, sfixed32, uint32, fixed32
@docs int64, sint64, sfixed64, uint64, fixed64
@docs int64AsInt, sint64AsInt, sfixed64AsInt, uint64AsInt, fixed64AsInt
@docs bool, string, bytes, bytesAsBytes, enum


# Messages

@docs embedded, messageEncoder, messageDecoder


# Well-known types

@docs timestamp, duration, fieldMask, empty, struct, listValue, value, any, anyWith
@docs doubleValue, floatValue, int64Value, int64ValueAsInt, uint64Value, uint64ValueAsInt
@docs int32Value, uint32Value, boolValue, stringValue, bytesValue, bytesValueAsBytes

-}

import Bitwise
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D exposing (Step(..))
import Bytes.Encode as E exposing (Encoder)
import Dict exposing (Dict)
import Json.Decode
import Json.Encode
import Proto.Bytes
import Proto.Duration exposing (Duration)
import Proto.Internal.Any as InternalAny exposing (Any, Payload(..))
import Proto.Internal.Binary as Internal
import Proto.Registry exposing (Registry)
import Time



-- RUNNING


{-| Decode a whole input as one message, with its generated decoder
(`decodeNoteBytes`); `Nothing` when the bytes are not that message.
-}
decode : Decoder a -> Bytes -> Maybe a
decode =
    Internal.run


{-| How a message is read from protobuf binary: generated code gives one per
message, `decodeNoteBytes : Decoder Note`, and one reading into a value
already read, `mergeNoteBytes : Note -> Decoder Note`. Run one with
[`decode`](#decode). The package site and compiler errors may show it as
`Proto.Internal.Binary.Decoder`, its name inside the package.
-}
type alias Decoder a =
    Internal.Decoder a


{-| A decoder whose value is changed by a function, as generated code wraps
a message that closes a cycle.
-}
map : (a -> b) -> Decoder a -> Decoder b
map f (Internal.Decoder decoder) =
    Internal.Decoder (\width -> D.map f (decoder width))


run : Decoder a -> Int -> D.Decoder a
run (Internal.Decoder decoder) =
    decoder


{-| Encode a message with its generated encoder (`encodeNoteBytes`).
-}
encode : (a -> Encoder) -> a -> Bytes
encode encoder input =
    E.encode (encoder input)



-- CODECS


{-| How one value of a field is read and written: its wire type, its
decoder and encoder, its default, and whether a repeated field of it is
packed. Each scalar and well-known type has one here; a generated message
has one by [`embedded`](#embedded).
-}
type Codec a
    = Codec
        { wire : Int
        , read : D.Decoder ( Int, a )
        , write : a -> Encoder
        , isDefault : a -> Bool
        , zero : a
        , packable : Bool
        , writeBody : a -> Encoder
        , readBody : Int -> D.Decoder a
        , readInto : a -> D.Decoder ( Int, a )
        }


scalar : Int -> D.Decoder ( Int, a ) -> (a -> Encoder) -> (a -> Bool) -> a -> Codec a
scalar wire read write isDefault zero =
    Codec
        { wire = wire
        , read = read
        , write = write
        , isDefault = isDefault
        , zero = zero
        , packable = wire /= 2
        , writeBody = write
        , readBody = \_ -> D.map Tuple.second read
        , readInto = \_ -> read
        }



-- DECODING A MESSAGE


{-| A message decoder reading into `start`: from a step that reads one field
into the value so far given the field's number and wire type, and a
function applied once every field is read. Generated code reverses its
lists there, which is why `merge` applies it to `start` too: a finished
value's lists turned back the way the step builds them, so repeated fields
read into a value add to its elements.

    mergeLeafBytes : Leaf -> Proto.Binary.Decoder Leaf
    mergeLeafBytes =
        Proto.Binary.merge
            (\number wire value ->
                case number of
                    1 ->
                        Proto.Binary.field Proto.Binary.string (\v -> { value | name = v }) wire value

                    _ ->
                        Proto.Binary.skip wire value
            )
            identity

    decodeLeafBytes : Proto.Binary.Decoder Leaf
    decodeLeafBytes =
        mergeLeafBytes defaultLeaf

-}
merge : (Int -> Int -> a -> D.Decoder ( Int, a )) -> (a -> a) -> a -> Decoder a
merge step finish start =
    Internal.Decoder (\width -> D.loop ( width, finish start ) (messageStep step finish))


{-| [`merge`](#merge) with the step given as a table: each field's number
beside the reader of that field, which takes the wire type and the value so
far. A number not in the table is skipped as an unknown field. The table is
built once per message type when the result is a top-level value.

    mergeLeafBytes : Leaf -> Proto.Binary.Decoder Leaf
    mergeLeafBytes =
        Proto.Binary.mergeTable
            [ ( 1, \w r -> Proto.Binary.field Proto.Binary.string (\v -> { r | name = v }) w r )
            ]
            identity

-}
mergeTable : List ( Int, Int -> a -> D.Decoder ( Int, a ) ) -> (a -> a) -> a -> Decoder a
mergeTable entries finish =
    let
        table =
            Dict.fromList entries
    in
    merge
        (\number wire current ->
            case Dict.get number table of
                Just read ->
                    read wire current

                Nothing ->
                    skip wire current
        )
        finish


message : a -> (Int -> Int -> a -> D.Decoder ( Int, a )) -> (a -> a) -> Int -> D.Decoder a
message default step finish width =
    D.loop ( width, default ) (messageStep step finish)


messageStep : (Int -> Int -> a -> D.Decoder ( Int, a )) -> (a -> a) -> ( Int, a ) -> D.Decoder (Step ( Int, a ) a)
messageStep step finish ( remaining, acc ) =
    if remaining == 0 then
        D.succeed (Done (finish acc))

    else if remaining < 0 then
        D.fail

    else
        varint32
            |> D.andThen
                (\( keyWidth, tag ) ->
                    let
                        number =
                            Bitwise.shiftRightZfBy 3 tag
                    in
                    if number == 0 then
                        D.fail

                    else
                        step number (Bitwise.and 7 tag) acc
                            |> D.map (\( width, next ) -> Loop ( remaining - keyWidth - width, next ))
                )


{-| Read a singular field, or a oneof member, of wire type `wire` and set
it with the function given; a field of another wire type is skipped,
leaving `current` as it is, as protobuf reads it: an unknown field.
-}
field : Codec v -> (v -> a) -> Int -> a -> D.Decoder ( Int, a )
field (Codec c) set wire current =
    if wire == c.wire then
        D.map (\( width, v ) -> ( width, set v )) c.read

    else
        skip wire current


{-| Read a singular message field, or a oneof's message member, into the
message read before it (`existing`, `Nothing` when none was), as protobuf
merges a message that arrives twice, and set it with the function given.
-}
fieldInto : Codec v -> Maybe v -> (v -> a) -> Int -> a -> D.Decoder ( Int, a )
fieldInto (Codec c) existing set wire current =
    if wire == c.wire then
        D.map (\( width, v ) -> ( width, set v ))
            (case existing of
                Just before ->
                    c.readInto before

                Nothing ->
                    c.read
            )

    else
        skip wire current


{-| Read an element of a repeated field, or all of a packed run of them,
onto the front of the elements read so far (`existing`); the message's
finishing function reverses the list. A field of another wire type is
skipped, leaving `current` as it is.
-}
repeated : Codec v -> (List v -> a) -> List v -> Int -> a -> D.Decoder ( Int, a )
repeated (Codec c) set existing wire current =
    if wire == c.wire then
        D.map (\( width, v ) -> ( width, set (v :: existing) )) c.read

    else if c.packable && wire == 2 then
        varint32
            |> D.andThen
                (\( lengthWidth, length ) ->
                    D.loop ( length, existing ) (packedStep c.read)
                        |> D.map (\vs -> ( lengthWidth + length, set vs ))
                )

    else
        skip wire current


packedStep : D.Decoder ( Int, v ) -> ( Int, List v ) -> D.Decoder (Step ( Int, List v ) (List v))
packedStep read ( remaining, acc ) =
    if remaining == 0 then
        D.succeed (Done acc)

    else if remaining < 0 then
        D.fail

    else
        D.map (\( width, v ) -> Loop ( remaining - width, v :: acc )) read


{-| Read one entry of a map field, its key and value defaulting to their
codecs' defaults when left out, and insert it with the function given; an
entry for a key read before replaces it. A field of another wire type is
skipped, leaving `current` as it is.
-}
mapEntry : Codec k -> Codec v -> (k -> v -> a) -> Int -> a -> D.Decoder ( Int, a )
mapEntry (Codec k) (Codec v) insert wire current =
    if wire /= 2 then
        skip wire current

    else
        varint32
            |> D.andThen
                (\( lengthWidth, length ) ->
                    D.loop ( length, ( k.zero, v.zero ) ) (entryStep k.wire k.read v.wire v.read)
                        |> D.map (\( key_, item ) -> ( lengthWidth + length, insert key_ item ))
                )


{-| A `bool`-keyed map's entry, put in place of any for the same key.
-}
insertBool : Bool -> v -> List ( Bool, v ) -> List ( Bool, v )
insertBool key item entries =
    ( key, item ) :: List.filter (\( k, _ ) -> k /= key) entries


entryStep : Int -> D.Decoder ( Int, k ) -> Int -> D.Decoder ( Int, v ) -> ( Int, ( k, v ) ) -> D.Decoder (Step ( Int, ( k, v ) ) ( k, v ))
entryStep keyWire readKey valueWire readItem ( remaining, ( key_, item ) as current ) =
    if remaining == 0 then
        D.succeed (Done current)

    else if remaining < 0 then
        D.fail

    else
        varint32
            |> D.andThen
                (\( tagWidth, tag ) ->
                    let
                        number =
                            Bitwise.shiftRightZfBy 3 tag

                        wire =
                            Bitwise.and 7 tag
                    in
                    if number == 1 && wire == keyWire then
                        D.map (\( width, next ) -> Loop ( remaining - tagWidth - width, ( next, item ) )) readKey

                    else if number == 2 && wire == valueWire then
                        D.map (\( width, next ) -> Loop ( remaining - tagWidth - width, ( key_, next ) )) readItem

                    else if number == 0 then
                        D.fail

                    else
                        D.map (\width -> Loop ( remaining - tagWidth - width, current )) (skipValue wire)
                )


{-| Skip a field the message does not know, by its wire type, leaving the
value as it is. A group (wire types 3 and 4) fails.
-}
skip : Int -> a -> D.Decoder ( Int, a )
skip wire unchanged =
    D.map (\width -> ( width, unchanged )) (skipValue wire)


skipValue : Int -> D.Decoder Int
skipValue wire =
    case wire of
        0 ->
            D.map Tuple.first varint32

        1 ->
            D.map (\_ -> 8) (D.bytes 8)

        2 ->
            varint32 |> D.andThen (\( width, length ) -> D.map (\_ -> width + length) (D.bytes length))

        5 ->
            D.map (\_ -> 4) (D.bytes 4)

        _ ->
            D.fail



-- ENCODING A MESSAGE


nothing : Encoder
nothing =
    E.sequence []


fieldKey : Int -> Int -> Encoder
fieldKey number wire =
    writeVarint32 (number * 8 + wire)


{-| A field without presence: left out at its default.
-}
implicit : Codec v -> Int -> v -> Encoder
implicit (Codec c) number v =
    if c.isDefault v then
        nothing

    else
        E.sequence [ fieldKey number c.wire, c.write v ]


{-| A field with presence: left out when `Nothing`.
-}
optional : Codec v -> Int -> Maybe v -> Encoder
optional codec number maybe =
    case maybe of
        Just v ->
            present codec number v

        Nothing ->
            nothing


{-| A field written whatever its value: a set oneof member, or a field of
`google.protobuf.Empty`.
-}
present : Codec v -> Int -> v -> Encoder
present (Codec c) number v =
    E.sequence [ fieldKey number c.wire, c.write v ]


{-| A repeated field: packed when its elements are scalars, as proto3
writes them; left out when empty.
-}
list : Codec v -> Int -> List v -> Encoder
list ((Codec c) as codec) number vs =
    case vs of
        [] ->
            nothing

        _ ->
            if c.packable then
                E.sequence [ fieldKey number 2, delimited (E.sequence (List.map c.write vs)) ]

            else
                E.sequence (List.map (present codec number) vs)


{-| A repeated scalar field declared `[packed = false]`: one field key per
element; left out when empty.
-}
listUnpacked : Codec v -> Int -> List v -> Encoder
listUnpacked codec number vs =
    E.sequence (List.map (present codec number) vs)


{-| A map field, its entries in the `Dict`'s order, each entry leaving out a
key or value at its default.
-}
dict : Codec k -> Codec v -> Int -> Dict k v -> Encoder
dict k v number entries =
    E.sequence (Dict.foldr (\key_ item acc -> entry k v number key_ item :: acc) [] entries)


{-| A map field with `bool` keys, its `False` entry first.
-}
boolMap : Codec v -> Int -> List ( Bool, v ) -> Encoder
boolMap v number entries =
    let
        ( trues, falses ) =
            List.partition Tuple.first entries
    in
    E.sequence (List.map (\( key_, item ) -> entry bool v number key_ item) (falses ++ trues))


entry : Codec k -> Codec v -> Int -> k -> v -> Encoder
entry k v number key_ item =
    E.sequence [ fieldKey number 2, delimited (E.sequence [ implicit k 1 key_, implicit v 2 item ]) ]


{-| `body` after its length. elm/bytes cannot tell an encoder's width
without running it, so the body is encoded first and copied in.
-}
delimited : Encoder -> Encoder
delimited body =
    let
        encoded =
            E.encode body
    in
    E.sequence [ writeVarint32 (Bytes.width encoded), E.bytes encoded ]



-- VARINTS


{-| A varint's width and its low 32 bits, unsigned; up to ten bytes are
read, the bits past the 32nd dropped.
-}
varint32 : D.Decoder ( Int, Int )
varint32 =
    D.unsignedInt8
        |> D.andThen
            (\b ->
                if b < 128 then
                    D.succeed ( 1, b )

                else
                    D.loop ( 1, b - 128 ) varint32Step
            )


varint32Step : ( Int, Int ) -> D.Decoder (Step ( Int, Int ) ( Int, Int ))
varint32Step ( index, low ) =
    D.unsignedInt8
        |> D.andThen
            (\b ->
                let
                    bits =
                        Bitwise.and 0x7F b

                    next =
                        if index < 4 then
                            low + bits * shift7 index

                        else if index == 4 then
                            low + Bitwise.and 0x0F bits * 268435456

                        else
                            low
                in
                if b < 128 then
                    D.succeed (Done ( index + 1, next ))

                else if index >= 9 then
                    D.fail

                else
                    D.succeed (Loop ( index + 1, next ))
            )


shift7 : Int -> Int
shift7 index =
    case index of
        0 ->
            1

        1 ->
            128

        2 ->
            16384

        _ ->
            2097152


{-| A 64-bit value as two unsigned 32-bit halves, high then low.
-}
type U64
    = U64 Int Int


varint64 : D.Decoder ( Int, U64 )
varint64 =
    D.unsignedInt8
        |> D.andThen
            (\b ->
                if b < 128 then
                    D.succeed ( 1, U64 0 b )

                else
                    D.loop ( 1, 0, b - 128 ) varint64Step
            )


varint64Step : ( Int, Int, Int ) -> D.Decoder (Step ( Int, Int, Int ) ( Int, U64 ))
varint64Step ( index, high, low ) =
    D.unsignedInt8
        |> D.andThen
            (\b ->
                let
                    bits =
                        Bitwise.and 0x7F b

                    ( nextHigh, nextLow ) =
                        if index < 4 then
                            ( high, low + bits * shift7 index )

                        else if index == 4 then
                            ( Bitwise.shiftRightZfBy 4 bits, low + Bitwise.and 0x0F bits * 268435456 )

                        else if index < 9 then
                            ( high + bits * (2 ^ (7 * index - 32)), low )

                        else
                            ( high + Bitwise.and 1 bits * 2147483648, low )
                in
                if b < 128 then
                    D.succeed (Done ( index + 1, U64 nextHigh nextLow ))

                else if index >= 9 then
                    D.fail

                else
                    D.succeed (Loop ( index + 1, nextHigh, nextLow ))
            )


{-| A varint of an unsigned value below 2^32.
-}
writeVarint32 : Int -> Encoder
writeVarint32 n =
    if n < 128 then
        E.unsignedInt8 n

    else
        E.sequence (List.map E.unsignedInt8 (varintBytes n))


{-| The bytes of a varint of `n`, any non-negative `Int` below 2^53.
-}
varintBytes : Int -> List Int
varintBytes n =
    if n < 128 then
        [ n ]

    else
        (modBy 128 n + 128) :: varintBytes (floor (toFloat n / 128))


writeVarint64 : U64 -> Encoder
writeVarint64 (U64 high low) =
    if high == 0 then
        writeVarint32 low

    else
        -- The low 28 bits, then the rest, which an Int holds exactly.
        E.sequence
            (List.map E.unsignedInt8
                ((Bitwise.and 0x7F low + 128)
                    :: (Bitwise.and 0x7F (Bitwise.shiftRightZfBy 7 low) + 128)
                    :: (Bitwise.and 0x7F (Bitwise.shiftRightZfBy 14 low) + 128)
                    :: (Bitwise.and 0x7F (Bitwise.shiftRightZfBy 21 low) + 128)
                    :: varintBytes (Bitwise.shiftRightZfBy 28 low + high * 16)
                )
            )


{-| A signed 32-bit value, sign-extended to ten bytes when negative.
-}
writeInt32 : Int -> Encoder
writeInt32 n =
    if n >= 0 then
        writeVarint32 n

    else
        writeVarint64 (U64 0xFFFFFFFF (Bitwise.shiftRightZfBy 0 n))


signed32 : Int -> Int
signed32 n =
    Bitwise.or n 0



-- 64-BIT VALUES


negate64 : U64 -> U64
negate64 (U64 high low) =
    let
        low_ =
            Bitwise.shiftRightZfBy 0 (Bitwise.complement low + 1)

        carry =
            if low_ == 0 then
                1

            else
                0
    in
    U64 (Bitwise.shiftRightZfBy 0 (Bitwise.complement high + carry)) low_


isNegative64 : U64 -> Bool
isNegative64 (U64 high _) =
    high >= 2147483648


{-| The decimal text of an unsigned 64-bit value.
-}
unsignedText : U64 -> String
unsignedText (U64 high low) =
    if high < 2097152 then
        String.fromInt (high * 4294967296 + low)

    else
        -- Four 16-bit limbs, divided by 10,000 until nothing is left.
        decimalGroups
            [ Bitwise.shiftRightZfBy 16 high
            , Bitwise.and 0xFFFF high
            , Bitwise.shiftRightZfBy 16 low
            , Bitwise.and 0xFFFF low
            ]
            []


decimalGroups : List Int -> List Int -> String
decimalGroups limbs groups =
    if List.all ((==) 0) limbs then
        case groups of
            [] ->
                "0"

            first :: rest ->
                String.fromInt first ++ String.concat (List.map (String.padLeft 4 '0' << String.fromInt) rest)

    else
        let
            ( quotient, remainder ) =
                List.foldl
                    (\limb ( done, carry ) ->
                        let
                            current =
                                carry * 65536 + limb
                        in
                        ( (current // 10000) :: done, modBy 10000 current )
                    )
                    ( [], 0 )
                    limbs
        in
        decimalGroups (List.reverse quotient) (remainder :: groups)


signedText : U64 -> String
signedText u =
    if isNegative64 u then
        "-" ++ unsignedText (negate64 u)

    else
        unsignedText u


{-| A decimal integer as 64 bits, two's complement when negative. Text that
is not one, which the generated code never holds, reads as 0.
-}
fromText : String -> U64
fromText text =
    let
        ( negative, digits ) =
            if String.startsWith "-" text then
                ( True, String.dropLeft 1 text )

            else
                ( False, text )

        magnitude =
            String.foldl
                (\char (U64 high low) ->
                    let
                        digit =
                            Char.toCode char - 48

                        widened =
                            low * 10 + digit

                        carry =
                            floor (toFloat widened / 4294967296)
                    in
                    if digit < 0 || digit > 9 then
                        U64 0 0

                    else
                        U64 (Bitwise.shiftRightZfBy 0 (high * 10 + carry)) (widened - carry * 4294967296)
                )
                (U64 0 0)
                digits
    in
    if negative then
        negate64 magnitude

    else
        magnitude


fromInt64 : Int -> U64
fromInt64 n =
    if n >= 0 then
        let
            high =
                floor (toFloat n / 4294967296)
        in
        U64 high (n - high * 4294967296)

    else
        negate64 (fromInt64 (negate n))


{-| The value as an `Int`, if within ±(2^53 − 1).
-}
toInt64 : U64 -> Maybe Int
toInt64 ((U64 high low) as u) =
    if isNegative64 u then
        case negate64 u of
            U64 h l ->
                if h < 2097152 then
                    Just (negate (h * 4294967296 + l))

                else
                    Nothing

    else if high < 2097152 then
        Just (high * 4294967296 + low)

    else
        Nothing


toUInt64 : U64 -> Maybe Int
toUInt64 (U64 high low) =
    if high < 2097152 then
        Just (high * 4294967296 + low)

    else
        Nothing


zigzag64 : U64 -> U64
zigzag64 (U64 high low) =
    let
        mask =
            Bitwise.shiftRightBy 31 high
    in
    U64
        (Bitwise.shiftRightZfBy 0 (Bitwise.xor (Bitwise.or (Bitwise.shiftLeftBy 1 high) (Bitwise.shiftRightZfBy 31 low)) mask))
        (Bitwise.shiftRightZfBy 0 (Bitwise.xor (Bitwise.shiftLeftBy 1 low) mask))


unzigzag64 : U64 -> U64
unzigzag64 (U64 high low) =
    let
        mask =
            negate (Bitwise.and 1 low)
    in
    U64
        (Bitwise.shiftRightZfBy 0 (Bitwise.xor (Bitwise.shiftRightZfBy 1 high) mask))
        (Bitwise.shiftRightZfBy 0 (Bitwise.xor (Bitwise.or (Bitwise.shiftRightZfBy 1 low) (Bitwise.shiftLeftBy 31 high)) mask))


fixed64Read : D.Decoder ( Int, U64 )
fixed64Read =
    D.map2 (\low high -> ( 8, U64 high low )) (D.unsignedInt32 LE) (D.unsignedInt32 LE)


fixed64Write : U64 -> Encoder
fixed64Write (U64 high low) =
    E.sequence [ E.unsignedInt32 LE low, E.unsignedInt32 LE high ]


{-| A 64-bit codec from how the bits are read and written and how they are
held.
-}
wide : Int -> D.Decoder ( Int, U64 ) -> (U64 -> Encoder) -> (U64 -> Maybe a) -> (a -> U64) -> a -> Codec a
wide wire read write hold unhold zero =
    scalar wire
        (read
            |> D.andThen
                (\( width, u ) ->
                    case hold u of
                        Just v ->
                            D.succeed ( width, v )

                        Nothing ->
                            D.fail
                )
        )
        (write << unhold)
        ((==) zero)
        zero



-- SCALARS


{-| `double`. NaN and the infinities travel as their bits; `-0` is left out
as a default, as `0` is.
-}
double : Codec Float
double =
    scalar 1 (D.map (\x -> ( 8, x )) (D.float64 LE)) (E.float64 LE) isZero 0


{-| `float`.
-}
float : Codec Float
float =
    scalar 5 (D.map (\x -> ( 4, x )) (D.float32 LE)) (E.float32 LE) isZero 0


isZero : Float -> Bool
isZero x =
    -- NaN first: `x == 0` alone is true of NaN in some compiled forms.
    not (isNaN x) && x == 0


{-| `int32`, a varint, ten bytes when negative.
-}
int32 : Codec Int
int32 =
    scalar 0 (D.map (\( width, n ) -> ( width, signed32 n )) varint32) writeInt32 ((==) 0) 0


{-| `sint32`, zigzag-encoded.
-}
sint32 : Codec Int
sint32 =
    scalar 0
        (D.map (\( width, z ) -> ( width, Bitwise.xor (Bitwise.shiftRightZfBy 1 z) (negate (Bitwise.and 1 z)) )) varint32)
        (\n -> writeVarint32 (Bitwise.shiftRightZfBy 0 (Bitwise.xor (Bitwise.shiftLeftBy 1 n) (Bitwise.shiftRightBy 31 n))))
        ((==) 0)
        0


{-| `sfixed32`, four bytes.
-}
sfixed32 : Codec Int
sfixed32 =
    scalar 5 (D.map (\n -> ( 4, n )) (D.signedInt32 LE)) (E.signedInt32 LE) ((==) 0) 0


{-| `uint32`, a varint.
-}
uint32 : Codec Int
uint32 =
    scalar 0 varint32 writeVarint32 ((==) 0) 0


{-| `fixed32`, four bytes.
-}
fixed32 : Codec Int
fixed32 =
    scalar 5 (D.map (\n -> ( 4, n )) (D.unsignedInt32 LE)) (E.unsignedInt32 LE) ((==) 0) 0


{-| `int64` held as decimal text.
-}
int64 : Codec String
int64 =
    wide 0 varint64 writeVarint64 (Just << signedText) fromText "0"


{-| `sint64` held as decimal text.
-}
sint64 : Codec String
sint64 =
    wide 0 (D.map (Tuple.mapSecond unzigzag64) varint64) (writeVarint64 << zigzag64) (Just << signedText) fromText "0"


{-| `sfixed64` held as decimal text.
-}
sfixed64 : Codec String
sfixed64 =
    wide 1 fixed64Read fixed64Write (Just << signedText) fromText "0"


{-| `uint64` held as decimal text.
-}
uint64 : Codec String
uint64 =
    wide 0 varint64 writeVarint64 (Just << unsignedText) fromText "0"


{-| `fixed64` held as decimal text.
-}
fixed64 : Codec String
fixed64 =
    wide 1 fixed64Read fixed64Write (Just << unsignedText) fromText "0"


{-| `int64` held as an `Int`, within ±(2^53 − 1).
-}
int64AsInt : Codec Int
int64AsInt =
    wide 0 varint64 writeVarint64 toInt64 fromInt64 0


{-| `sint64` held as an `Int`.
-}
sint64AsInt : Codec Int
sint64AsInt =
    wide 0 (D.map (Tuple.mapSecond unzigzag64) varint64) (writeVarint64 << zigzag64) toInt64 fromInt64 0


{-| `sfixed64` held as an `Int`.
-}
sfixed64AsInt : Codec Int
sfixed64AsInt =
    wide 1 fixed64Read fixed64Write toInt64 fromInt64 0


{-| `uint64` held as an `Int`, within 0 to 2^53 − 1.
-}
uint64AsInt : Codec Int
uint64AsInt =
    wide 0 varint64 writeVarint64 toUInt64 fromInt64 0


{-| `fixed64` held as an `Int`.
-}
fixed64AsInt : Codec Int
fixed64AsInt =
    wide 1 fixed64Read fixed64Write toUInt64 fromInt64 0


{-| `bool`, any non-zero varint reading as `True`.
-}
bool : Codec Bool
bool =
    scalar 0
        (D.map (\( width, n ) -> ( width, n /= 0 )) varint64Any)
        (\b ->
            if b then
                E.unsignedInt8 1

            else
                E.unsignedInt8 0
        )
        not
        False


varint64Any : D.Decoder ( Int, Int )
varint64Any =
    D.map (\( width, U64 high low ) -> ( width, high + low )) varint64


{-| `string`, UTF-8.
-}
string : Codec String
string =
    scalar 2
        (varint32 |> D.andThen (\( width, length ) -> D.map (\s -> ( width + length, s )) (D.string length)))
        (\s -> E.sequence [ writeVarint32 (E.getStringWidth s), E.string s ])
        String.isEmpty
        ""


rawBytes : D.Decoder ( Int, Bytes )
rawBytes =
    varint32 |> D.andThen (\( width, length ) -> D.map (\b -> ( width + length, b )) (D.bytes length))


writeBytes : Bytes -> Encoder
writeBytes b =
    E.sequence [ writeVarint32 (Bytes.width b), E.bytes b ]


{-| `bytes` held as base64 text, as the generated code holds it by default:
read as standard base64 with padding, written from either alphabet.
-}
bytes : Codec String
bytes =
    scalar 2
        (D.map (Tuple.mapSecond Proto.Bytes.toBase64) rawBytes)
        (\text -> writeBytes (Maybe.withDefault Proto.Bytes.empty (Proto.Bytes.fromBase64 text)))
        String.isEmpty
        ""


{-| `bytes` held as `Bytes`, under `bytes=bytes`.
-}
bytesAsBytes : Codec Bytes
bytesAsBytes =
    scalar 2 rawBytes writeBytes (\b -> Bytes.width b == 0) Proto.Bytes.empty


{-| An enum, from its generated number conversions: a number it does not
know reads as its zero value.
-}
enum : (a -> Int) -> (Int -> a) -> Codec a
enum toNumber fromNumber =
    scalar 0
        (D.map (\( width, n ) -> ( width, fromNumber (signed32 n) )) varint32)
        (writeInt32 << toNumber)
        (\v -> toNumber v == 0)
        (fromNumber 0)



-- MESSAGES


{-| A message field's codec, from the message's generated encoder, its
decoder into a value read before (`mergeNoteBytes`) and its default:
length-delimited, and written whenever present.
-}
embedded : (a -> Encoder) -> (a -> Decoder a) -> a -> Codec a
embedded write into zero =
    let
        readInto existing =
            varint32 |> D.andThen (\( width, length ) -> D.map (\v -> ( width + length, v )) (run (into existing) length))
    in
    Codec
        { wire = 2
        , read = readInto zero
        , write = \v -> delimited (write v)
        , isDefault = \_ -> False
        , zero = zero
        , packable = False
        , writeBody = write
        , readBody = \length -> run (into zero) length
        , readInto = readInto
        }


{-| The encoder of a whole message from its codec, for a well-known type
a method takes: `messageEncoder Proto.Binary.empty`.
-}
messageEncoder : Codec a -> a -> Encoder
messageEncoder (Codec c) =
    c.writeBody


{-| The decoder of a whole message from its codec, for a well-known type a
method answers.
-}
messageDecoder : Codec a -> Decoder a
messageDecoder (Codec c) =
    Internal.Decoder c.readBody



-- WELL-KNOWN TYPES


{-| `google.protobuf.Timestamp` as `Time.Posix`: nanoseconds past the
millisecond are dropped when read. One that arrives twice is merged field by
field, as protobuf merges any message: the seconds or the nanoseconds the
later one carries replace the earlier one's.
-}
timestamp : Codec Time.Posix
timestamp =
    embedded writeTimestamp timestampInto (Time.millisToPosix 0)


timestampInto : Time.Posix -> Decoder Time.Posix
timestampInto existing =
    let
        millis =
            Time.posixToMillis existing

        seconds =
            floor (toFloat millis / 1000)
    in
    Internal.Decoder
        (message ( seconds, (millis - seconds * 1000) * 1000000 ) partsStep identity
            >> D.map (\( s, nanos ) -> Time.millisToPosix (s * 1000 + floor (toFloat nanos / 1.0e6)))
        )


{-| A `Timestamp`'s or a `Duration`'s fields: `seconds` (1) and `nanos` (2).
-}
partsStep : Int -> Int -> ( Int, Int ) -> D.Decoder ( Int, ( Int, Int ) )
partsStep number wire ( seconds, nanos ) =
    case number of
        1 ->
            field int64AsInt (\v -> ( v, nanos )) wire ( seconds, nanos )

        2 ->
            field int32 (\v -> ( seconds, v )) wire ( seconds, nanos )

        _ ->
            skip wire ( seconds, nanos )


writeTimestamp : Time.Posix -> Encoder
writeTimestamp posix =
    let
        millis =
            Time.posixToMillis posix

        seconds =
            floor (toFloat millis / 1000)
    in
    E.sequence [ implicit int64AsInt 1 seconds, implicit int32 2 ((millis - seconds * 1000) * 1000000) ]


{-| `google.protobuf.Duration`, exact. One that arrives twice is merged field
by field: the seconds or the nanoseconds the later one carries replace the
earlier one's, and the two are then given one sign as
[`Proto.Duration.fromParts`](Proto-Duration#fromParts) does.
-}
duration : Codec Duration
duration =
    embedded writeDuration durationInto (Proto.Duration.fromParts 0 0)


durationInto : Duration -> Decoder Duration
durationInto existing =
    let
        parts =
            Proto.Duration.toParts existing
    in
    Internal.Decoder
        (message ( parts.seconds, parts.nanos ) partsStep identity
            >> D.map (\( seconds, nanos ) -> Proto.Duration.fromParts seconds nanos)
        )


writeDuration : Duration -> Encoder
writeDuration d =
    let
        parts =
            Proto.Duration.toParts d
    in
    E.sequence [ implicit int64AsInt 1 parts.seconds, implicit int32 2 parts.nanos ]


{-| `google.protobuf.FieldMask` as its paths, proto field names as the
binary form carries them. One that arrives twice adds its paths after the
earlier one's.
-}
fieldMask : Codec (List String)
fieldMask =
    embedded (list string 1)
        (merge
            (\number wire paths ->
                if number == 1 then
                    repeated string identity paths wire paths

                else
                    skip wire paths
            )
            List.reverse
        )
        []


{-| `google.protobuf.Empty` as `()`.
-}
empty : Codec ()
empty =
    embedded (\() -> nothing) (merge (\_ wire acc -> skip wire acc) identity) ()


{-| `google.protobuf.Struct` as its members. One that arrives twice adds its
members to the earlier one's, a member of the same name replacing the
earlier.
-}
struct : Codec (Dict String Json.Encode.Value)
struct =
    structCodec ()


{-| `google.protobuf.ListValue` as its elements. One that arrives twice adds
its elements after the earlier one's.
-}
listValue : Codec (List Json.Encode.Value)
listValue =
    listCodec ()


{-| `google.protobuf.Value` as JSON: an object's members are written in key
order. One that arrives twice replaces the earlier, unless both hold an
object, whose members are then merged as `struct`'s, or both a list, whose
elements are then added after the earlier ones, as protobuf merges a oneof's
message member.
-}
value : Codec Json.Encode.Value
value =
    valueCodec ()


{-| The codecs of the three types that hold each other, built on use, since
Elm's values cannot refer to themselves.
-}
structCodec : () -> Codec (Dict String Json.Encode.Value)
structCodec () =
    embedded writeStruct structInto Dict.empty


listCodec : () -> Codec (List Json.Encode.Value)
listCodec () =
    embedded writeList listInto []


valueCodec : () -> Codec Json.Encode.Value
valueCodec () =
    embedded writeValue valueInto Json.Encode.null


structInto : Dict String Json.Encode.Value -> Decoder (Dict String Json.Encode.Value)
structInto =
    merge
        (\number wire members ->
            if number == 1 then
                mapEntry string (valueCodec ()) (\k v -> Dict.insert k v members) wire members

            else
                skip wire members
        )
        identity


writeStruct : Dict String Json.Encode.Value -> Encoder
writeStruct members =
    dict string (valueCodec ()) 1 members


listInto : List Json.Encode.Value -> Decoder (List Json.Encode.Value)
listInto =
    merge
        (\number wire items ->
            if number == 1 then
                repeated (valueCodec ()) identity items wire items

            else
                skip wire items
        )
        List.reverse


writeList : List Json.Encode.Value -> Encoder
writeList items =
    list (valueCodec ()) 1 items


valueInto : Json.Encode.Value -> Decoder Json.Encode.Value
valueInto =
    merge
        (\number wire current ->
            case number of
                1 ->
                    field int32 (\_ -> Json.Encode.null) wire current

                2 ->
                    field double Json.Encode.float wire current

                3 ->
                    field string Json.Encode.string wire current

                4 ->
                    field bool Json.Encode.bool wire current

                5 ->
                    fieldInto (structCodec ())
                        (Json.Decode.decodeValue (Json.Decode.dict Json.Decode.value) current |> Result.toMaybe)
                        (Json.Encode.dict identity identity)
                        wire
                        current

                6 ->
                    fieldInto (listCodec ())
                        (Json.Decode.decodeValue (Json.Decode.list Json.Decode.value) current |> Result.toMaybe)
                        (Json.Encode.list identity)
                        wire
                        current

                _ ->
                    skip wire current
        )
        identity


type Json
    = JNull
    | JBool Bool
    | JNumber Float
    | JString String
    | JArray (List Json.Encode.Value)
    | JObject (Dict String Json.Encode.Value)


classify : Json.Decode.Decoder Json
classify =
    Json.Decode.oneOf
        [ Json.Decode.null JNull
        , Json.Decode.map JBool Json.Decode.bool
        , Json.Decode.map JNumber Json.Decode.float
        , Json.Decode.map JString Json.Decode.string
        , Json.Decode.map JArray (Json.Decode.list Json.Decode.value)
        , Json.Decode.map JObject (Json.Decode.dict Json.Decode.value)
        ]


writeValue : Json.Encode.Value -> Encoder
writeValue json =
    case Json.Decode.decodeValue classify json of
        Ok (JBool b) ->
            present bool 4 b

        Ok (JNumber x) ->
            present double 2 x

        Ok (JString s) ->
            present string 3 s

        Ok (JArray items) ->
            present (listCodec ()) 6 items

        Ok (JObject members) ->
            present (structCodec ()) 5 members

        _ ->
            present int32 1 0


{-| `google.protobuf.Any`: read, it holds the packed message's binary, which
[`Proto.Any.unpack`](Proto-Any#unpack) decodes with a message that has binary
codecs. Written, an `Any` packed from such a message writes that binary; one
holding a message's JSON alone, as one read from proto3 JSON does, is written
with its type URL alone, since no binary encoder is at hand: generated code
under `codec=both` writes with [`anyWith`](#anyWith) its package's
`binaryRegistry`, which converts the JSON. One that arrives twice is merged field by field: the
type URL or the value the later one carries replaces the earlier one's.
-}
any : Codec Any
any =
    anyWith Proto.Registry.empty


{-| [`any`](#any), writing an `Any` that holds a message's JSON alone as the
message's binary when the registry has the message's codecs
([`Proto.Registry.withBinary`](Proto-Registry#withBinary)), and with its type
URL alone when it does not.

    Proto.Binary.optional (Proto.Binary.anyWith Notes.V1.binaryRegistry) 13 value.attachment

-}
anyWith : Registry -> Codec Any
anyWith registry =
    embedded (writeAny registry) anyInto (InternalAny.Any "" (InBinary ""))


anyInto : Any -> Decoder Any
anyInto (InternalAny.Any start payload) =
    Internal.Decoder
        (message ( start, payload )
            (\number wire ( url, current ) ->
                case number of
                    1 ->
                        field string (\v -> ( v, current )) wire ( url, current )

                    2 ->
                        field bytes (\v -> ( url, InBinary v )) wire ( url, current )

                    _ ->
                        skip wire ( url, current )
            )
            identity
            >> D.map (\( url, current ) -> InternalAny.Any url current)
        )


writeAny : Registry -> Any -> Encoder
writeAny registry (InternalAny.Any url payload) =
    case payload of
        InBinary base64 ->
            E.sequence [ implicit string 1 url, implicit bytes 2 base64 ]

        InBoth _ base64 ->
            E.sequence [ implicit string 1 url, implicit bytes 2 base64 ]

        InJson json ->
            case Proto.Registry.toBinary (InternalAny.nameOf url) json registry of
                Just body ->
                    E.sequence [ implicit string 1 url, implicit bytesAsBytes 2 body ]

                Nothing ->
                    implicit string 1 url


wrapper : Codec v -> Codec v
wrapper ((Codec c) as inner) =
    embedded (implicit inner 1)
        (merge
            (\number wire current ->
                if number == 1 then
                    field inner identity wire current

                else
                    skip wire current
            )
            identity
        )
        c.zero


{-| `google.protobuf.DoubleValue` as its `Float`.
-}
doubleValue : Codec Float
doubleValue =
    wrapper double


{-| `google.protobuf.FloatValue` as its `Float`.
-}
floatValue : Codec Float
floatValue =
    wrapper float


{-| `google.protobuf.Int64Value` as decimal text.
-}
int64Value : Codec String
int64Value =
    wrapper int64


{-| `google.protobuf.Int64Value` as an `Int`.
-}
int64ValueAsInt : Codec Int
int64ValueAsInt =
    wrapper int64AsInt


{-| `google.protobuf.UInt64Value` as decimal text.
-}
uint64Value : Codec String
uint64Value =
    wrapper uint64


{-| `google.protobuf.UInt64Value` as an `Int`.
-}
uint64ValueAsInt : Codec Int
uint64ValueAsInt =
    wrapper uint64AsInt


{-| `google.protobuf.Int32Value` as its `Int`.
-}
int32Value : Codec Int
int32Value =
    wrapper int32


{-| `google.protobuf.UInt32Value` as its `Int`.
-}
uint32Value : Codec Int
uint32Value =
    wrapper uint32


{-| `google.protobuf.BoolValue` as its `Bool`.
-}
boolValue : Codec Bool
boolValue =
    wrapper bool


{-| `google.protobuf.StringValue` as its `String`.
-}
stringValue : Codec String
stringValue =
    wrapper string


{-| `google.protobuf.BytesValue` as base64 text.
-}
bytesValue : Codec String
bytesValue =
    wrapper bytes


{-| `google.protobuf.BytesValue` as `Bytes`.
-}
bytesValueAsBytes : Codec Bytes
bytesValueAsBytes =
    wrapper bytesAsBytes
