module Proto.Binary exposing
    ( decode, encode, Decoder, map
    , Codec
    , merge, Field, field, fieldInto, repeated, mapEntry, insertBool, skip
    , implicit, optional, present, list, listUnpacked, dict, boolMap
    , double, float
    , int32, sint32, sfixed32, uint32, fixed32
    , int64, sint64, sfixed64, uint64, fixed64
    , int64AsInt, sint64AsInt, sfixed64AsInt, uint64AsInt, fixed64AsInt
    , bool, string, bytes, bytesAsBytes, enum
    , embedded, messageEncoder, messageDecoder
    , timestamp, duration, fieldMask, empty, struct, listValue, value, any
    , doubleValue, floatValue, int64Value, int64ValueAsInt, uint64Value, uint64ValueAsInt
    , int32Value, uint32Value, boolValue, stringValue, bytesValue, bytesValueAsBytes
    )

{-| The protobuf binary wire format, over elm/bytes: the helpers generated
binary codecs (`encodeNoteBytes`, `decodeNoteBytes`) are written with.

A message's [`Decoder`](#Decoder) reads it from a whole input with
[`decode`](#decode), or into a value already read, as protobuf merges a
message that arrives twice.

    Proto.Binary.decode Notes.V1.decodeNoteBytes body
    --> Ok note

Encoders write fields in field-number order, leave out a field without
presence at its default, and write a map's entries in the order of its
`Dict` (a `bool`-keyed map's `False` entry first), so the same value always
gives the same bytes. Decoders read fields in any order, the last of a
repeated singular field winning and a message field merged into the one
read before it, read a repeated scalar packed or not, and skip a field they
do not know, or one of a wire type its declaration does not take, by its
wire type; a group, a length past the end, a varint longer than ten bytes
and a `string` that is not UTF-8 fail, with a
[`Proto.Error.Binary`](Proto-Error#Binary) saying why and where.

64-bit integers are held as the generated code holds them: a decimal
`String`, exact, or an `Int` (the `AsInt` codecs) that fails to decode
outside ±(2^53 − 1).

@docs decode, encode, Decoder, map


# Codecs

@docs Codec


# Decoding a message

@docs merge, Field, field, fieldInto, repeated, mapEntry, insertBool, skip


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

@docs timestamp, duration, fieldMask, empty, struct, listValue, value, any
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
import Proto.Error exposing (Reason(..))
import Proto.Internal.Any as InternalAny exposing (Any)
import Proto.Internal.Binary as Internal exposing (Failure)
import Time



-- RUNNING


{-| Decode a whole input as one message, with its generated decoder
(`decodeNoteBytes`), or say why the bytes are not that message: the
[`Reason`](Proto-Error#Reason), the fields it is in and the offset of the
first byte that could not be read.

    Proto.Binary.decode Notes.V1.decodeNoteBytes truncated
    --> Err { typeName = "notes.v1.Note", reason = Proto.Error.Truncated, path = [ ( "notes.v1.Note", 2 ) ], offset = 9 }

-}
decode : Decoder a -> Bytes -> Result Proto.Error.Binary a
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
map f (Internal.Decoder d) =
    Internal.Decoder
        { name = d.name
        , fast = \width -> D.map f (d.fast width)
        , located = \width -> D.map (Result.map f) (d.located width)
        }


run : Decoder a -> Int -> D.Decoder (Result Failure a)
run (Internal.Decoder d) =
    d.located


fastRun : Decoder a -> Int -> D.Decoder a
fastRun (Internal.Decoder d) =
    d.fast


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
        -- Each value has two readers. The fast one (`fast`, `fastBody`,
        -- `fastInto`) fails without saying why. The locating one (`read`,
        -- `readBody`, `readInto`) is given the bytes left in the region it
        -- reads in, never reads past them, and says why it failed.
        { wire : Int
        , fast : D.Decoder ( Int, a )
        , fastBody : Int -> D.Decoder a
        , fastInto : a -> D.Decoder ( Int, a )
        , read : Int -> Read a
        , write : a -> Encoder
        , isDefault : a -> Bool
        , zero : a
        , packable : Bool

        -- The fast reader of a whole packed run of these values given its
        -- length, onto the values read before, when the codec has one
        -- quicker than a read per value.
        , run : Maybe (Int -> List a -> D.Decoder (List a))
        , writeBody : a -> Encoder
        , readBody : Int -> D.Decoder (Result Failure a)
        , readInto : a -> Int -> Read a

        -- A message's full name, for a decoder of the whole message; asked
        -- for only then, since an embedded codec is built at every use and
        -- finding the name builds the message's decoder.
        , name : () -> String
        }


{-| A value read and its width, or why it could not be.
-}
type alias Read a =
    D.Decoder (Result Failure ( Int, a ))


{-| A scalar's codec from its fast reader and its raw reader given the
bytes left, which gives a negative width for a failure (see
[`leaf`](#leaf)). `widest` is the most bytes it reads: with that many left
it reads from one decoder built once.
-}
scalar : Int -> Int -> D.Decoder ( Int, a ) -> (Int -> D.Decoder ( Int, a )) -> (a -> Encoder) -> (a -> Bool) -> a -> Codec a
scalar =
    scalarRun Nothing


{-| [`scalar`](#scalar) with a fast reader of a whole packed run (see
[`fixedRun`](#fixedRun), [`varintRun`](#varintRun)).
-}
scalarRun : Maybe (Int -> List a -> D.Decoder (List a)) -> Int -> Int -> D.Decoder ( Int, a ) -> (Int -> D.Decoder ( Int, a )) -> (a -> Encoder) -> (a -> Bool) -> a -> Codec a
scalarRun run_ wire widest fast raw write isDefault zero =
    let
        free =
            D.map checked (raw widest)
    in
    rawCodec run_
        wire
        fast
        (\bound ->
            if bound >= widest then
                free

            else
                D.map checked (raw bound)
        )
        write
        isDefault
        zero


{-| A length-delimited scalar's codec, whose raw reader checks its length
against the bytes left.
-}
delimitedScalar : D.Decoder ( Int, a ) -> (Int -> D.Decoder ( Int, a )) -> (a -> Encoder) -> (a -> Bool) -> a -> Codec a
delimitedScalar fast raw write isDefault zero =
    rawCodec Nothing 2 fast (\bound -> D.map checked (raw bound)) write isDefault zero


rawCodec : Maybe (Int -> List a -> D.Decoder (List a)) -> Int -> D.Decoder ( Int, a ) -> (Int -> Read a) -> (a -> Encoder) -> (a -> Bool) -> a -> Codec a
rawCodec run_ wire fast read write isDefault zero =
    Codec
        { wire = wire
        , fast = fast
        , fastBody = \_ -> D.map Tuple.second fast
        , fastInto = \_ -> fast
        , read = read
        , write = write
        , isDefault = isDefault
        , zero = zero
        , packable = wire /= 2
        , run = run_
        , writeBody = write
        , readBody = \width -> D.map (Result.map Tuple.second) (read width)
        , readInto = \_ -> read
        , name = \_ -> ""
        }


checked : ( Int, a ) -> Result Failure ( Int, a )
checked (( width, _ ) as read) =
    if width < 0 then
        Err (leaf width)

    else
        Ok read


{-| The failure a raw reader's negative width stands for: -1 a varint longer
than ten bytes, -3 a value out of range, -4 a string whose bytes are not
UTF-8, any other a read past the end of the region.
-}
leaf : Int -> Failure
leaf code =
    { reason =
        if code == -1 then
            MalformedVarint

        else if code == -3 then
            OutOfRange

        else if code == -4 then
            InvalidUtf8

        else
            Truncated
    , path = []
    , offset = 0
    }


pastEnd : Failure
pastEnd =
    leaf -2



-- DECODING A MESSAGE


{-| One field read into the value so far, as a message's step gives it
to [`merge`](#merge): built by [`field`](#field), [`fieldInto`](#fieldInto),
[`repeated`](#repeated), [`mapEntry`](#mapEntry) or [`skip`](#skip).
-}
type Field a
    = Field
        -- The fast reader, given the bytes left in the message after the
        -- field's key and giving the message loop's next step; and the
        -- locating one, given the bytes left in the region it reads in.
        { fast : Int -> D.Decoder (Step ( Int, a ) a)
        , located : Int -> Read a
        }


{-| A message decoder reading into `start`: from the message's full name, a
step that reads one field into the value so far given the field's number
and wire type, and a function applied once every field is read. Generated
code reverses its lists there, which is why `merge` applies it to `start`
too: a finished value's lists turned back the way the step builds them, so
repeated fields read into a value add to its elements.

    mergeLeafBytes : Leaf -> Proto.Binary.Decoder Leaf
    mergeLeafBytes =
        Proto.Binary.merge "pkg.Leaf"
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
merge : String -> (Int -> Int -> a -> Field a) -> (a -> a) -> a -> Decoder a
merge name step finish start =
    let
        first =
            finish start
    in
    Internal.Decoder
        { name = name
        , fast = fastMessage first step finish
        , located = message name first step finish
        }


fastMessage : a -> (Int -> Int -> a -> Field a) -> (a -> a) -> Int -> D.Decoder a
fastMessage start step finish width =
    D.loop ( width, start ) (fastMessageStep step finish)


fastMessageStep : (Int -> Int -> a -> Field a) -> (a -> a) -> ( Int, a ) -> D.Decoder (Step ( Int, a ) a)
fastMessageStep step finish ( remaining, acc ) =
    if remaining == 0 then
        D.succeed (Done (finish acc))

    else if remaining < 0 then
        D.fail

    else
        -- A key below 128, one byte, is read without the varint reader.
        D.unsignedInt8
            |> D.andThen
                (\b ->
                    if b < 128 then
                        fastField step remaining 1 b acc

                    else
                        fastVarint32From b |> D.andThen (\( keyWidth, tag ) -> fastField step remaining keyWidth tag acc)
                )


fastField : (Int -> Int -> a -> Field a) -> Int -> Int -> Int -> a -> D.Decoder (Step ( Int, a ) a)
fastField step remaining keyWidth tag acc =
    let
        number =
            Bitwise.shiftRightZfBy 3 tag
    in
    if number == 0 then
        D.fail

    else
        case step number (Bitwise.and 7 tag) acc of
            Field f ->
                f.fast (remaining - keyWidth)


message : String -> a -> (Int -> Int -> a -> Field a) -> (a -> a) -> Int -> D.Decoder (Result Failure a)
message name start step finish width =
    D.loop ( width, start ) (messageStep name width step finish)


{-| Wire types 3, 4, 6 and 7, as bits of a byte.
-}
invalidWire : Int -> Bool
invalidWire wire =
    Bitwise.and 1 (Bitwise.shiftRightZfBy wire 0xD8) == 1


messageStep : String -> Int -> (Int -> Int -> a -> Field a) -> (a -> a) -> ( Int, a ) -> D.Decoder (Step ( Int, a ) (Result Failure a))
messageStep name width step finish ( remaining, acc ) =
    if remaining == 0 then
        D.succeed (Done (Ok (finish acc)))

    else
        varint32 remaining
            |> D.andThen
                (\( keyWidth, tag ) ->
                    let
                        start =
                            width - remaining
                    in
                    if keyWidth < 0 then
                        D.succeed (Done (Err { reason = (leaf keyWidth).reason, path = [], offset = start }))

                    else
                        let
                            number =
                                Bitwise.shiftRightZfBy 3 tag

                            wire =
                                Bitwise.and 7 tag
                        in
                        if number == 0 then
                            D.succeed (Done (Err { reason = InvalidTag, path = [ ( name, 0 ) ], offset = start }))

                        else if invalidWire wire then
                            D.succeed (Done (Err { reason = InvalidWireType wire, path = [ ( name, number ) ], offset = start }))

                        else
                            case step number wire acc of
                                Field f ->
                                    f.located (remaining - keyWidth)
                                        |> D.map
                                            (\result ->
                                                case result of
                                                    Ok ( fieldWidth, next ) ->
                                                        Loop ( remaining - keyWidth - fieldWidth, next )

                                                    Err failure ->
                                                        Done (Err { reason = failure.reason, path = ( name, number ) :: failure.path, offset = failure.offset + start + keyWidth })
                                            )
                )


{-| Read a singular field, or a oneof member, of wire type `wire` and set
it with the function given; a field of another wire type is skipped,
leaving `current` as it is, as protobuf reads it: an unknown field.
-}
field : Codec v -> (v -> a) -> Int -> a -> Field a
field (Codec c) set wire current =
    if wire == c.wire then
        Field
            { fast = \left -> D.map (\( width, v ) -> Loop ( left - width, set v )) c.fast
            , located = \bound -> D.map (setWith set) (c.read bound)
            }

    else
        skip wire current


setWith : (v -> a) -> Result Failure ( Int, v ) -> Result Failure ( Int, a )
setWith set result =
    case result of
        Ok ( width, v ) ->
            Ok ( width, set v )

        Err failure ->
            Err failure


{-| Read a singular message field, or a oneof's message member, into the
message read before it (`existing`, `Nothing` when none was), as protobuf
merges a message that arrives twice, and set it with the function given.
-}
fieldInto : Codec v -> Maybe v -> (v -> a) -> Int -> a -> Field a
fieldInto (Codec c) existing set wire current =
    if wire == c.wire then
        case existing of
            Just before ->
                Field
                    { fast = \left -> D.map (\( width, v ) -> Loop ( left - width, set v )) (c.fastInto before)
                    , located = \bound -> D.map (setWith set) (c.readInto before bound)
                    }

            Nothing ->
                Field
                    { fast = \left -> D.map (\( width, v ) -> Loop ( left - width, set v )) c.fast
                    , located = \bound -> D.map (setWith set) (c.read bound)
                    }

    else
        skip wire current


{-| Read an element of a repeated field, or all of a packed run of them,
onto the front of the elements read so far (`existing`); the message's
finishing function reverses the list. A field of another wire type is
skipped, leaving `current` as it is.
-}
repeated : Codec v -> (List v -> a) -> List v -> Int -> a -> Field a
repeated (Codec c) set existing wire current =
    if wire == c.wire then
        Field
            { fast = \left -> D.map (\( width, v ) -> Loop ( left - width, set (v :: existing) )) c.fast
            , located = \bound -> D.map (setWith (\v -> set (v :: existing))) (c.read bound)
            }

    else if c.packable && wire == 2 then
        Field
            { fast =
                \left ->
                    fastVarint32
                        |> D.andThen
                            (\( lengthWidth, length ) ->
                                (case c.run of
                                    Just readRun ->
                                        readRun length existing

                                    Nothing ->
                                        D.loop ( length, existing ) (fastPackedStep c.fast)
                                )
                                    |> D.map (\vs -> Loop ( left - lengthWidth - length, set vs ))
                            )
            , located = \bound -> packed c.read set existing bound
            }

    else
        skip wire current


packed : (Int -> Read v) -> (List v -> a) -> List v -> Int -> Read a
packed read set existing bound =
    varint32 bound
        |> D.andThen
            (\( lengthWidth, length ) ->
                if lengthWidth < 0 then
                    D.succeed (Err (leaf lengthWidth))

                else if length > bound - lengthWidth then
                    D.succeed (Err pastEnd)

                else
                    D.loop ( length, existing ) (packedStep read length)
                        |> D.map
                            (\result ->
                                case result of
                                    Ok vs ->
                                        Ok ( lengthWidth + length, set vs )

                                    Err failure ->
                                        Err (Internal.crossed lengthWidth failure)
                            )
            )


fastPackedStep : D.Decoder ( Int, v ) -> ( Int, List v ) -> D.Decoder (Step ( Int, List v ) (List v))
fastPackedStep read ( remaining, acc ) =
    if remaining == 0 then
        D.succeed (Done acc)

    else if remaining < 0 then
        D.fail

    else
        D.map (\( width, v ) -> Loop ( remaining - width, v :: acc )) read


{-| A codec whose packed runs are read `width` bytes a value by `plain`, four
values a step: a run whose length is not a multiple of `width` fails, as
reading it value by value would past its end.
-}
fixedRun : Int -> D.Decoder a -> Maybe (Int -> List a -> D.Decoder (List a))
fixedRun width plain =
    Just
        (\length existing ->
            if modBy width length /= 0 then
                D.fail

            else
                D.loop ( length // width, existing ) (fixedRunStep plain)
        )


fixedRunStep : D.Decoder a -> ( Int, List a ) -> D.Decoder (Step ( Int, List a ) (List a))
fixedRunStep plain ( count, acc ) =
    if count >= 4 then
        D.map4 (\a b c d -> Loop ( count - 4, d :: c :: b :: a :: acc )) plain plain plain plain

    else if count > 0 then
        D.map (\a -> Loop ( count - 1, a :: acc )) plain

    else
        D.succeed (Done acc)


{-| A codec of a 32-bit varint kind whose packed runs are read as words and
parsed by a plain function, each varint's low 32 bits given to `f`: up to
ten bytes a varint, and a run that ends inside one fails, as reading it
value by value would.
-}
varintRun : (Int -> a) -> Maybe (Int -> List a -> D.Decoder (List a))
varintRun f =
    Just
        (\length existing ->
            D.loop ( length, [] ) wordStep
                |> D.andThen
                    (\words ->
                        case parseVarints f (List.reverse words) length 0 0 0 existing of
                            Just vs ->
                                D.succeed vs

                            Nothing ->
                                D.fail
                    )
        )


{-| A run's bytes as big-endian words, the last holding what is left in its
high bytes; newest first.
-}
wordStep : ( Int, List Int ) -> D.Decoder (Step ( Int, List Int ) (List Int))
wordStep ( remaining, acc ) =
    if remaining >= 4 then
        D.map (\w -> Loop ( remaining - 4, w :: acc )) (D.unsignedInt32 BE)

    else if remaining == 3 then
        D.map2 (\h l -> Done ((h * 65536 + l * 256) :: acc)) (D.unsignedInt16 BE) D.unsignedInt8

    else if remaining == 2 then
        D.map (\h -> Done ((h * 65536) :: acc)) (D.unsignedInt16 BE)

    else if remaining == 1 then
        D.map (\b -> Done ((b * 16777216) :: acc)) D.unsignedInt8

    else
        D.succeed (Done acc)


{-| The varints in `left` bytes of `words`, `index` bytes into one whose low
bits so far are `low`, `at` bytes into the current word.
-}
parseVarints : (Int -> a) -> List Int -> Int -> Int -> Int -> Int -> List a -> Maybe (List a)
parseVarints f words left at index low acc =
    if left == 0 then
        if index == 0 then
            Just acc

        else
            Nothing

    else
        case words of
            w :: rest ->
                let
                    b =
                        Bitwise.and 0xFF (Bitwise.shiftRightZfBy (24 - 8 * at) w)

                    next =
                        if index < 4 then
                            low + Bitwise.and 0x7F b * shift7 index

                        else if index == 4 then
                            low + Bitwise.and 0x0F b * 268435456

                        else
                            low

                    words_ =
                        if at == 3 then
                            rest

                        else
                            words

                    at_ =
                        if at == 3 then
                            0

                        else
                            at + 1
                in
                if b < 128 then
                    parseVarints f words_ (left - 1) at_ 0 0 (f next :: acc)

                else if index >= 9 then
                    Nothing

                else
                    parseVarints f words_ (left - 1) at_ (index + 1) next acc

            [] ->
                Nothing


packedStep : (Int -> Read v) -> Int -> ( Int, List v ) -> D.Decoder (Step ( Int, List v ) (Result Failure (List v)))
packedStep read length ( remaining, acc ) =
    if remaining == 0 then
        D.succeed (Done (Ok acc))

    else
        D.map
            (\result ->
                case result of
                    Ok ( width, v ) ->
                        Loop ( remaining - width, v :: acc )

                    Err failure ->
                        Done (Err { failure | offset = failure.offset + length - remaining })
            )
            (read remaining)


{-| Read one entry of a map field, its key and value defaulting to their
codecs' defaults when left out, and insert it with the function given; an
entry for a key read before replaces it. A field of another wire type is
skipped, leaving `current` as it is.
-}
mapEntry : Codec k -> Codec v -> (k -> v -> a) -> Int -> a -> Field a
mapEntry (Codec k) (Codec v) insert wire current =
    if wire /= 2 then
        skip wire current

    else
        Field
            { fast =
                \left ->
                    fastVarint32
                        |> D.andThen
                            (\( lengthWidth, length ) ->
                                D.loop ( length, ( k.zero, v.zero ) ) (fastEntryStep k.wire k.fast v.wire v.fast)
                                    |> D.map (\( key_, item ) -> Loop ( left - lengthWidth - length, insert key_ item ))
                            )
            , located = \bound -> locatedEntry k.wire k.read k.zero v.wire v.read v.zero insert bound
            }


locatedEntry : Int -> (Int -> Read k) -> k -> Int -> (Int -> Read v) -> v -> (k -> v -> a) -> Int -> Read a
locatedEntry keyWire readKey keyZero valueWire readItem valueZero insert bound =
    varint32 bound
        |> D.andThen
            (\( lengthWidth, length ) ->
                if lengthWidth < 0 then
                    D.succeed (Err (leaf lengthWidth))

                else if length > bound - lengthWidth then
                    D.succeed (Err pastEnd)

                else
                    D.loop ( length, ( keyZero, valueZero ) ) (entryStep length keyWire readKey valueWire readItem)
                        |> D.map
                            (\result ->
                                case result of
                                    Ok ( key_, item ) ->
                                        Ok ( lengthWidth + length, insert key_ item )

                                    Err failure ->
                                        Err (Internal.crossed lengthWidth failure)
                            )
            )


{-| A `bool`-keyed map's entry, put in place of any for the same key.
-}
insertBool : Bool -> v -> List ( Bool, v ) -> List ( Bool, v )
insertBool key item entries =
    ( key, item ) :: List.filter (\( k, _ ) -> k /= key) entries


fastEntryStep : Int -> D.Decoder ( Int, k ) -> Int -> D.Decoder ( Int, v ) -> ( Int, ( k, v ) ) -> D.Decoder (Step ( Int, ( k, v ) ) ( k, v ))
fastEntryStep keyWire readKey valueWire readItem ( remaining, current ) =
    if remaining == 0 then
        D.succeed (Done current)

    else if remaining < 0 then
        D.fail

    else
        D.unsignedInt8
            |> D.andThen
                (\b ->
                    if b < 128 then
                        fastEntryField keyWire readKey valueWire readItem remaining current 1 b

                    else
                        fastVarint32From b |> D.andThen (\( tagWidth, tag ) -> fastEntryField keyWire readKey valueWire readItem remaining current tagWidth tag)
                )


fastEntryField : Int -> D.Decoder ( Int, k ) -> Int -> D.Decoder ( Int, v ) -> Int -> ( k, v ) -> Int -> Int -> D.Decoder (Step ( Int, ( k, v ) ) ( k, v ))
fastEntryField keyWire readKey valueWire readItem remaining (( key_, item ) as current) tagWidth tag =
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
        D.map (\width -> Loop ( remaining - tagWidth - width, current )) (fastSkipValue wire)


entryStep : Int -> Int -> (Int -> Read k) -> Int -> (Int -> Read v) -> ( Int, ( k, v ) ) -> D.Decoder (Step ( Int, ( k, v ) ) (Result Failure ( k, v )))
entryStep length keyWire readKey valueWire readItem ( remaining, ( key_, item ) as current ) =
    if remaining == 0 then
        D.succeed (Done (Ok current))

    else
        varint32 remaining
            |> D.andThen
                (\( tagWidth, tag ) ->
                    let
                        start =
                            length - remaining

                        number =
                            Bitwise.shiftRightZfBy 3 tag

                        wire =
                            Bitwise.and 7 tag

                        after result rebuild =
                            case result of
                                Ok ( width, next ) ->
                                    Loop ( remaining - tagWidth - width, rebuild next )

                                Err failure ->
                                    Done (Err { failure | offset = failure.offset + start + tagWidth })
                    in
                    if tagWidth < 0 then
                        D.succeed (Done (Err { reason = (leaf tagWidth).reason, path = [], offset = start }))

                    else if number == 1 && wire == keyWire then
                        D.map (\result -> after result (\next -> ( next, item ))) (readKey (remaining - tagWidth))

                    else if number == 2 && wire == valueWire then
                        D.map (\result -> after result (\next -> ( key_, next ))) (readItem (remaining - tagWidth))

                    else if number == 0 then
                        D.succeed (Done (Err { reason = InvalidTag, path = [], offset = start }))

                    else if invalidWire wire then
                        D.succeed (Done (Err { reason = InvalidWireType wire, path = [], offset = start }))

                    else
                        D.map (\width -> after (skipped width current) identity) (skipValue wire (remaining - tagWidth))
                )


skipped : Int -> a -> Result Failure ( Int, a )
skipped width unchanged =
    if width < 0 then
        Err (leaf width)

    else
        Ok ( width, unchanged )


{-| Skip a field the message does not know, by its wire type, leaving the
value as it is. A group (wire types 3 and 4) fails the fast reader here and
the located one at the field's key.
-}
skip : Int -> a -> Field a
skip wire unchanged =
    Field
        { fast = \left -> D.map (\width -> Loop ( left - width, unchanged )) (fastSkipValue wire)
        , located = \bound -> D.map (\width -> skipped width unchanged) (skipValue wire bound)
        }


fastSkipValue : Int -> D.Decoder Int
fastSkipValue wire =
    case wire of
        0 ->
            D.map Tuple.first fastVarint32

        1 ->
            D.map (\_ -> 8) (D.bytes 8)

        2 ->
            fastVarint32 |> D.andThen (\( width, length ) -> D.map (\_ -> width + length) (D.bytes length))

        5 ->
            D.map (\_ -> 4) (D.bytes 4)

        _ ->
            D.fail


skipValue : Int -> Int -> D.Decoder Int
skipValue wire bound =
    case wire of
        0 ->
            D.map Tuple.first (varint32 bound)

        1 ->
            if bound >= 8 then
                D.map (\_ -> 8) (D.bytes 8)

            else
                D.succeed -2

        2 ->
            varint32 bound
                |> D.andThen
                    (\( width, length ) ->
                        if width < 0 then
                            D.succeed width

                        else if length > bound - width then
                            D.succeed -2

                        else
                            D.map (\_ -> width + length) (D.bytes length)
                    )

        5 ->
            if bound >= 4 then
                D.map (\_ -> 4) (D.bytes 4)

            else
                D.succeed -2

        _ ->
            D.succeed -2



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


{-| A varint's width and its low 32 bits, unsigned, read from no more than
`bound` bytes; up to ten bytes are read, the bits past the 32nd dropped. Its
width is -1 when it is longer than ten bytes and -2 when it runs past
`bound`.
-}
varint32 : Int -> D.Decoder ( Int, Int )
varint32 bound =
    if bound >= 10 then
        varint32Free

    else
        varint32Within bound


varint32Free : D.Decoder ( Int, Int )
varint32Free =
    varint32Within 10


varint32Within : Int -> D.Decoder ( Int, Int )
varint32Within bound =
    if bound < 1 then
        D.succeed ( -2, 0 )

    else
        D.unsignedInt8
            |> D.andThen
                (\b ->
                    if b < 128 then
                        D.succeed ( 1, b )

                    else
                        D.loop ( 1, b - 128 ) (varint32Step bound)
                )


varint32Step : Int -> ( Int, Int ) -> D.Decoder (Step ( Int, Int ) ( Int, Int ))
varint32Step bound ( index, low ) =
    if index >= bound then
        D.succeed (Done ( -2, 0 ))

    else
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
                        D.succeed (Done ( -1, 0 ))

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


varint64 : Int -> D.Decoder ( Int, U64 )
varint64 bound =
    if bound < 1 then
        D.succeed ( -2, U64 0 0 )

    else
        D.unsignedInt8
            |> D.andThen
                (\b ->
                    if b < 128 then
                        D.succeed ( 1, U64 0 b )

                    else
                        D.loop ( 1, 0, b - 128 ) (varint64Step bound)
                )


varint64Step : Int -> ( Int, Int, Int ) -> D.Decoder (Step ( Int, Int, Int ) ( Int, U64 ))
varint64Step bound ( index, high, low ) =
    if index >= bound then
        D.succeed (Done ( -2, U64 0 0 ))

    else
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
                        D.succeed (Done ( -1, U64 0 0 ))

                    else
                        D.succeed (Loop ( index + 1, nextHigh, nextLow ))
                )


{-| A varint's width and its low 32 bits, unsigned, for the fast reader;
up to ten bytes are read, the bits past the 32nd dropped.
-}
fastVarint32 : D.Decoder ( Int, Int )
fastVarint32 =
    D.unsignedInt8 |> D.andThen fastVarint32From


{-| [`fastVarint32`](#fastVarint32) with its value changed by `f`, a one-byte
varint without a second map.
-}
fastVarint32Map : (Int -> a) -> D.Decoder ( Int, a )
fastVarint32Map f =
    D.unsignedInt8
        |> D.andThen
            (\b ->
                if b < 128 then
                    D.succeed ( 1, f b )

                else
                    D.map (\( width, n ) -> ( width, f n )) (fastVarint32From b)
            )


{-| [`fastVarint32`](#fastVarint32) once its first byte, `b0`, is read. The
bytes are read by a fixed chain rather than a loop: most varints are one or
two bytes, and a loop's state tuple and step cost more than the read.
-}
fastVarint32From : Int -> D.Decoder ( Int, Int )
fastVarint32From b0 =
    if b0 < 128 then
        D.succeed ( 1, b0 )

    else
        D.unsignedInt8
            |> D.andThen
                (\b1 ->
                    let
                        v1 =
                            b0 - 128 + Bitwise.and 0x7F b1 * 128
                    in
                    if b1 < 128 then
                        D.succeed ( 2, v1 )

                    else
                        D.unsignedInt8
                            |> D.andThen
                                (\b2 ->
                                    let
                                        v2 =
                                            v1 + Bitwise.and 0x7F b2 * 16384
                                    in
                                    if b2 < 128 then
                                        D.succeed ( 3, v2 )

                                    else
                                        D.unsignedInt8
                                            |> D.andThen
                                                (\b3 ->
                                                    let
                                                        v3 =
                                                            v2 + Bitwise.and 0x7F b3 * 2097152
                                                    in
                                                    if b3 < 128 then
                                                        D.succeed ( 4, v3 )

                                                    else
                                                        D.unsignedInt8
                                                            |> D.andThen
                                                                (\b4 ->
                                                                    let
                                                                        v4 =
                                                                            v3 + Bitwise.and 0x0F b4 * 268435456
                                                                    in
                                                                    if b4 < 128 then
                                                                        D.succeed ( 5, v4 )

                                                                    else
                                                                        fastVarint32Tail 5 v4
                                                                )
                                                )
                                )
                )


{-| The bytes of a varint past its fifth, which hold no bits of the low 32:
read up to the tenth, failing on an eleventh.
-}
fastVarint32Tail : Int -> Int -> D.Decoder ( Int, Int )
fastVarint32Tail index low =
    D.unsignedInt8
        |> D.andThen
            (\b ->
                if b < 128 then
                    D.succeed ( index + 1, low )

                else if index >= 9 then
                    D.fail

                else
                    fastVarint32Tail (index + 1) low
            )


fastVarint64 : D.Decoder ( Int, U64 )
fastVarint64 =
    D.unsignedInt8 |> D.andThen fastVarint64From


{-| [`fastVarint64`](#fastVarint64) once its first byte is read: the low 32
bits as [`fastVarint32From`](#fastVarint32From) reads them, then the high.
-}
fastVarint64From : Int -> D.Decoder ( Int, U64 )
fastVarint64From b0 =
    if b0 < 128 then
        D.succeed ( 1, U64 0 b0 )

    else
        D.unsignedInt8
            |> D.andThen
                (\b1 ->
                    let
                        v1 =
                            b0 - 128 + Bitwise.and 0x7F b1 * 128
                    in
                    if b1 < 128 then
                        D.succeed ( 2, U64 0 v1 )

                    else
                        D.unsignedInt8
                            |> D.andThen
                                (\b2 ->
                                    let
                                        v2 =
                                            v1 + Bitwise.and 0x7F b2 * 16384
                                    in
                                    if b2 < 128 then
                                        D.succeed ( 3, U64 0 v2 )

                                    else
                                        D.unsignedInt8
                                            |> D.andThen
                                                (\b3 ->
                                                    let
                                                        v3 =
                                                            v2 + Bitwise.and 0x7F b3 * 2097152
                                                    in
                                                    if b3 < 128 then
                                                        D.succeed ( 4, U64 0 v3 )

                                                    else
                                                        D.unsignedInt8
                                                            |> D.andThen
                                                                (\b4 ->
                                                                    let
                                                                        low =
                                                                            v3 + Bitwise.and 0x0F b4 * 268435456

                                                                        high =
                                                                            Bitwise.shiftRightZfBy 4 (Bitwise.and 0x7F b4)
                                                                    in
                                                                    if b4 < 128 then
                                                                        D.succeed ( 5, U64 high low )

                                                                    else
                                                                        fastVarint64High 5 high low
                                                                )
                                                )
                                )
                )


{-| The bytes of a varint past its fifth, which hold its high bits: read up
to the tenth, failing on an eleventh.
-}
fastVarint64High : Int -> Int -> Int -> D.Decoder ( Int, U64 )
fastVarint64High index high low =
    D.unsignedInt8
        |> D.andThen
            (\b ->
                let
                    next =
                        if index < 9 then
                            high + Bitwise.and 0x7F b * highShift index

                        else
                            high + Bitwise.and 1 b * 2147483648
                in
                if b < 128 then
                    D.succeed ( index + 1, U64 next low )

                else if index >= 9 then
                    D.fail

                else
                    fastVarint64High (index + 1) next low
            )


{-| 2^(7 × index − 32): where byte `index` (5 to 8) of a varint puts its
seven bits in the high half.
-}
highShift : Int -> Int
highShift index =
    case index of
        5 ->
            8

        6 ->
            1024

        7 ->
            131072

        _ ->
            16777216


{-| A varint of an unsigned value below 2^32, written as few integers as
its width allows (one u16 for two bytes, one u32 for four) rather than a
list of bytes.
-}
writeVarint32 : Int -> Encoder
writeVarint32 n =
    if n < 128 then
        E.unsignedInt8 n

    else if n < 16384 then
        E.unsignedInt16 LE (Bitwise.or (Bitwise.and 0x7F n) 0x80 + Bitwise.shiftLeftBy 8 (Bitwise.shiftRightZfBy 7 n))

    else if n < 2097152 then
        E.sequence
            [ E.unsignedInt16 LE (Bitwise.or (Bitwise.and 0x7F7F (spread n)) 0x8080)
            , E.unsignedInt8 (Bitwise.shiftRightZfBy 14 n)
            ]

    else if n < 268435456 then
        E.unsignedInt32 LE (Bitwise.or (spread n) 0x00808080)

    else
        E.sequence
            [ E.unsignedInt32 LE (Bitwise.or (spread n) 0x80808080)
            , E.unsignedInt8 (Bitwise.shiftRightZfBy 28 n)
            ]


{-| The low 28 bits of `n` as four 7-bit groups, one per byte, low first,
without their continuation bits.
-}
spread : Int -> Int
spread n =
    Bitwise.and 0x7F n
        + Bitwise.shiftLeftBy 8 (Bitwise.and 0x7F (Bitwise.shiftRightZfBy 7 n))
        + Bitwise.shiftLeftBy 16 (Bitwise.and 0x7F (Bitwise.shiftRightZfBy 14 n))
        + Bitwise.shiftLeftBy 24 (Bitwise.and 0x7F (Bitwise.shiftRightZfBy 21 n))


writeVarint64 : U64 -> Encoder
writeVarint64 (U64 high low) =
    if high == 0 then
        writeVarint32 low

    else
        -- The low 28 bits, then the rest, below 2^36, which an Int holds
        -- exactly: 28 more bits if it has them, then what is left.
        let
            rest =
                Bitwise.shiftRightZfBy 28 low + high * 16
        in
        if rest < 268435456 then
            E.sequence [ E.unsignedInt32 LE (Bitwise.or (spread low) 0x80808080), writeVarint32 rest ]

        else
            E.sequence
                [ E.unsignedInt32 LE (Bitwise.or (spread low) 0x80808080)
                , E.unsignedInt32 LE (Bitwise.or (spread rest) 0x80808080)
                , writeVarint32 (rest // 268435456)
                ]


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


fastFixed64 : D.Decoder ( Int, U64 )
fastFixed64 =
    D.map2 (\low high -> ( 8, U64 high low )) (D.unsignedInt32 LE) (D.unsignedInt32 LE)


fixed64Read : Int -> D.Decoder ( Int, U64 )
fixed64Read =
    fixed 8 (U64 0 0) (D.map2 (\low high -> ( 8, U64 high low )) (D.unsignedInt32 LE) (D.unsignedInt32 LE))


{-| A fixed-width read of `width` bytes, or -2 when fewer are left.
-}
fixed : Int -> a -> D.Decoder ( Int, a ) -> Int -> D.Decoder ( Int, a )
fixed width zero decoder bound =
    if bound >= width then
        decoder

    else
        D.succeed ( -2, zero )


fixed64Write : U64 -> Encoder
fixed64Write (U64 high low) =
    E.sequence [ E.unsignedInt32 LE low, E.unsignedInt32 LE high ]


{-| A 64-bit codec from how the bits are read (fast, and given the bytes
left) and written and how they are held; a value the holding cannot hold
fails the fast reader and reads as -3.
-}
wide : Int -> D.Decoder ( Int, U64 ) -> (Int -> D.Decoder ( Int, U64 )) -> (U64 -> Encoder) -> (U64 -> Maybe a) -> (a -> U64) -> a -> Codec a
wide wire fast read write hold unhold zero =
    scalarRun
        (if wire == 1 then
            fixedRun 8
                (D.map2 (\low high -> U64 high low) (D.unsignedInt32 LE) (D.unsignedInt32 LE)
                    |> D.andThen
                        (\u ->
                            case hold u of
                                Just v ->
                                    D.succeed v

                                Nothing ->
                                    D.fail
                        )
                )

         else
            Nothing
        )
        wire
        (if wire == 0 then
            10

         else
            8
        )
        (fast
            |> D.andThen
                (\( width, u ) ->
                    case hold u of
                        Just v ->
                            D.succeed ( width, v )

                        Nothing ->
                            D.fail
                )
        )
        (\bound ->
            read bound
                |> D.map
                    (\( width, u ) ->
                        if width < 0 then
                            ( width, zero )

                        else
                            case hold u of
                                Just v ->
                                    ( width, v )

                                Nothing ->
                                    ( -3, zero )
                    )
        )
        (write << unhold)
        ((==) zero)
        zero


{-| A varint's low 32 bits, as `f` reads them.
-}
fromVarint32 : (Int -> a) -> a -> Int -> D.Decoder ( Int, a )
fromVarint32 f zero bound =
    D.map
        (\( width, n ) ->
            if width < 0 then
                ( width, zero )

            else
                ( width, f n )
        )
        (varint32 bound)



-- SCALARS


{-| `double`. NaN and the infinities travel as their bits; `-0` is left out
as a default, as `0` is.
-}
double : Codec Float
double =
    scalarRun (fixedRun 8 (D.float64 LE)) 1 8 (D.map (\x -> ( 8, x )) (D.float64 LE)) (fixed 8 0 (D.map (\x -> ( 8, x )) (D.float64 LE))) (E.float64 LE) isZero 0


{-| `float`.
-}
float : Codec Float
float =
    scalarRun (fixedRun 4 (D.float32 LE)) 5 4 (D.map (\x -> ( 4, x )) (D.float32 LE)) (fixed 4 0 (D.map (\x -> ( 4, x )) (D.float32 LE))) (E.float32 LE) isZero 0


isZero : Float -> Bool
isZero x =
    -- NaN first: `x == 0` alone is true of NaN in some compiled forms.
    not (isNaN x) && x == 0


{-| `int32`, a varint, ten bytes when negative.
-}
int32 : Codec Int
int32 =
    scalarRun (varintRun signed32) 0 10 (fastVarint32Map signed32) (fromVarint32 signed32 0) writeInt32 ((==) 0) 0


{-| `sint32`, zigzag-encoded.
-}
sint32 : Codec Int
sint32 =
    scalarRun (varintRun (\z -> Bitwise.xor (Bitwise.shiftRightZfBy 1 z) (negate (Bitwise.and 1 z))))
        0
        10
        (fastVarint32Map (\z -> Bitwise.xor (Bitwise.shiftRightZfBy 1 z) (negate (Bitwise.and 1 z))))
        (fromVarint32 (\z -> Bitwise.xor (Bitwise.shiftRightZfBy 1 z) (negate (Bitwise.and 1 z))) 0)
        (\n -> writeVarint32 (Bitwise.shiftRightZfBy 0 (Bitwise.xor (Bitwise.shiftLeftBy 1 n) (Bitwise.shiftRightBy 31 n))))
        ((==) 0)
        0


{-| `sfixed32`, four bytes.
-}
sfixed32 : Codec Int
sfixed32 =
    scalarRun (fixedRun 4 (D.signedInt32 LE)) 5 4 (D.map (\n -> ( 4, n )) (D.signedInt32 LE)) (fixed 4 0 (D.map (\n -> ( 4, n )) (D.signedInt32 LE))) (E.signedInt32 LE) ((==) 0) 0


{-| `uint32`, a varint.
-}
uint32 : Codec Int
uint32 =
    scalarRun (varintRun identity) 0 10 fastVarint32 varint32 writeVarint32 ((==) 0) 0


{-| `fixed32`, four bytes.
-}
fixed32 : Codec Int
fixed32 =
    scalarRun (fixedRun 4 (D.unsignedInt32 LE)) 5 4 (D.map (\n -> ( 4, n )) (D.unsignedInt32 LE)) (fixed 4 0 (D.map (\n -> ( 4, n )) (D.unsignedInt32 LE))) (E.unsignedInt32 LE) ((==) 0) 0


{-| `int64` held as decimal text.
-}
int64 : Codec String
int64 =
    wide 0 fastVarint64 varint64 writeVarint64 (Just << signedText) fromText "0"


{-| `sint64` held as decimal text.
-}
sint64 : Codec String
sint64 =
    wide 0 (D.map (Tuple.mapSecond unzigzag64) fastVarint64) (varint64 >> D.map (Tuple.mapSecond unzigzag64)) (writeVarint64 << zigzag64) (Just << signedText) fromText "0"


{-| `sfixed64` held as decimal text.
-}
sfixed64 : Codec String
sfixed64 =
    wide 1 fastFixed64 fixed64Read fixed64Write (Just << signedText) fromText "0"


{-| `uint64` held as decimal text.
-}
uint64 : Codec String
uint64 =
    wide 0 fastVarint64 varint64 writeVarint64 (Just << unsignedText) fromText "0"


{-| `fixed64` held as decimal text.
-}
fixed64 : Codec String
fixed64 =
    wide 1 fastFixed64 fixed64Read fixed64Write (Just << unsignedText) fromText "0"


{-| `int64` held as an `Int`, within ±(2^53 − 1).
-}
int64AsInt : Codec Int
int64AsInt =
    wide 0 fastVarint64 varint64 writeVarint64 toInt64 fromInt64 0


{-| `sint64` held as an `Int`.
-}
sint64AsInt : Codec Int
sint64AsInt =
    wide 0 (D.map (Tuple.mapSecond unzigzag64) fastVarint64) (varint64 >> D.map (Tuple.mapSecond unzigzag64)) (writeVarint64 << zigzag64) toInt64 fromInt64 0


{-| `sfixed64` held as an `Int`.
-}
sfixed64AsInt : Codec Int
sfixed64AsInt =
    wide 1 fastFixed64 fixed64Read fixed64Write toInt64 fromInt64 0


{-| `uint64` held as an `Int`, within 0 to 2^53 − 1.
-}
uint64AsInt : Codec Int
uint64AsInt =
    wide 0 fastVarint64 varint64 writeVarint64 toUInt64 fromInt64 0


{-| `fixed64` held as an `Int`.
-}
fixed64AsInt : Codec Int
fixed64AsInt =
    wide 1 fastFixed64 fixed64Read fixed64Write toUInt64 fromInt64 0


{-| `bool`, any non-zero varint reading as `True`.
-}
bool : Codec Bool
bool =
    scalar 0
        10
        (D.unsignedInt8
            |> D.andThen
                (\b ->
                    if b < 128 then
                        D.succeed ( 1, b /= 0 )

                    else
                        D.map (\( width, U64 high low ) -> ( width, high + low /= 0 )) (fastVarint64From b)
                )
        )
        (\bound -> D.map (\( width, U64 high low ) -> ( width, width >= 0 && high + low /= 0 )) (varint64 bound))
        (\b ->
            if b then
                E.unsignedInt8 1

            else
                E.unsignedInt8 0
        )
        not
        False


{-| A length-delimited value's raw reader: its length, checked against the
bytes left, then `body` of that length.
-}
delimitedRead : a -> (Int -> D.Decoder a) -> Int -> D.Decoder ( Int, a )
delimitedRead zero body bound =
    varint32 bound
        |> D.andThen
            (\( width, length ) ->
                if width < 0 then
                    D.succeed ( width, zero )

                else if length > bound - width then
                    D.succeed ( -2, zero )

                else
                    D.map (\v -> ( width + length, v )) (body length)
            )


{-| `string`, UTF-8. A string whose bytes are not UTF-8 fails the decode,
as proto3 requires.
-}
string : Codec String
string =
    delimitedScalar fastString
        utf8String
        (\s -> E.sequence [ writeVarint32 (E.getStringWidth s), E.string s ])
        String.isEmpty
        ""


fastString : D.Decoder ( Int, String )
fastString =
    fastVarint32
        |> D.andThen
            (\( width, length ) ->
                D.bytes length
                    |> D.andThen
                        (\slice ->
                            case utf8 length slice of
                                Just s ->
                                    D.succeed ( width + length, s )

                                Nothing ->
                                    D.fail
                        )
            )


{-| A string's raw reader: its length checked against the bytes left, then
read as [`utf8`](#utf8) does, -4 when its bytes are not UTF-8.
-}
utf8String : Int -> D.Decoder ( Int, String )
utf8String bound =
    varint32 bound
        |> D.andThen
            (\( width, length ) ->
                if width < 0 then
                    D.succeed ( width, "" )

                else if length > bound - width then
                    D.succeed ( -2, "" )

                else
                    D.map
                        (\slice ->
                            case utf8 length slice of
                                Just s ->
                                    ( width + length, s )

                                Nothing ->
                                    ( -4, "" )
                        )
                        (D.bytes length)
            )


{-| A string's bytes, `length` of them in a slice of their own, if they are
UTF-8.

The slice keeps elm/bytes inside the string: it reads a byte that does not
begin a character as the lead of four, and as a string's last character
would otherwise read on past its end. elm/bytes checks nothing else, so
the bytes are checked here, only when they hold a byte past ASCII: elm/bytes
gives fewer UTF-16 code units than bytes for any such byte, and one per
byte for ASCII, so a string as long as its bytes is ASCII and valid.

-}
utf8 : Int -> Bytes -> Maybe String
utf8 length slice =
    case D.decode (D.string length) slice of
        Just s ->
            if String.length s == length || D.decode (D.loop ( length, 0 ) utf8Step) slice == Just 0 then
                Just s

            else
                Nothing

        Nothing ->
            Nothing


{-| A UTF-8 check over the bytes left, sixteen at a time while they are
ASCII: the state is 0 between characters, -1 once a byte is wrong, and
otherwise the continuation bytes still owed times 8 plus the range the next
must be in (see `utf8Byte`).
-}
utf8Step : ( Int, Int ) -> D.Decoder (Step ( Int, Int ) Int)
utf8Step ( remaining, state ) =
    if state < 0 then
        D.succeed (Done state)

    else if remaining >= 16 then
        D.map4
            (\a b c d ->
                if state == 0 && Bitwise.and (Bitwise.or (Bitwise.or a b) (Bitwise.or c d)) 0x80808080 == 0 then
                    Loop ( remaining - 16, 0 )

                else
                    Loop ( remaining - 16, utf8Word d (utf8Word c (utf8Word b (utf8Word a state))) )
            )
            word
            word
            word
            word

    else if remaining >= 4 then
        D.map (\w -> Loop ( remaining - 4, utf8Word w state )) word

    else if remaining > 0 then
        D.map (\b -> Loop ( remaining - 1, utf8Byte b state )) D.unsignedInt8

    else
        D.succeed (Done state)


word : D.Decoder Int
word =
    D.unsignedInt32 BE


utf8Word : Int -> Int -> Int
utf8Word w state =
    if state == 0 && Bitwise.and w 0x80808080 == 0 then
        0

    else
        utf8Byte (Bitwise.and 0xFF w)
            (utf8Byte (Bitwise.and 0xFF (Bitwise.shiftRightZfBy 8 w))
                (utf8Byte (Bitwise.and 0xFF (Bitwise.shiftRightZfBy 16 w))
                    (utf8Byte (Bitwise.shiftRightZfBy 24 w) state)
                )
            )


{-| The state after one more byte. The ranges a continuation byte must be
in: 0 is 80–BF, 1 A0–BF (after E0), 2 80–9F (after ED), 3 90–BF (after
F0), 4 80–8F (after F4), which rules out overlong forms, surrogates and
code points past U+10FFFF.
-}
utf8Byte : Int -> Int -> Int
utf8Byte b state =
    if state < 0 then
        -1

    else if state == 0 then
        if b < 0x80 then
            0

        else if b < 0xC2 then
            -1

        else if b < 0xE0 then
            8

        else if b == 0xE0 then
            17

        else if b == 0xED then
            18

        else if b < 0xF0 then
            16

        else if b == 0xF0 then
            27

        else if b < 0xF4 then
            24

        else if b == 0xF4 then
            28

        else
            -1

    else if outOfRange (Bitwise.and 7 state) b then
        -1

    else if state < 16 then
        0

    else
        Bitwise.shiftRightBy 3 state * 8 - 8


outOfRange : Int -> Int -> Bool
outOfRange range b =
    case range of
        1 ->
            b < 0xA0 || b > 0xBF

        2 ->
            b < 0x80 || b > 0x9F

        3 ->
            b < 0x90 || b > 0xBF

        4 ->
            b < 0x80 || b > 0x8F

        _ ->
            b < 0x80 || b > 0xBF


fastRawBytes : D.Decoder ( Int, Bytes )
fastRawBytes =
    fastVarint32 |> D.andThen (\( width, length ) -> D.map (\b -> ( width + length, b )) (D.bytes length))


rawBytes : Int -> D.Decoder ( Int, Bytes )
rawBytes =
    delimitedRead Proto.Bytes.empty D.bytes


writeBytes : Bytes -> Encoder
writeBytes b =
    E.sequence [ writeVarint32 (Bytes.width b), E.bytes b ]


{-| `bytes` held as base64 text, as the generated code holds it by default:
read as standard base64 with padding, written from either alphabet.
-}
bytes : Codec String
bytes =
    delimitedScalar
        (D.map (Tuple.mapSecond Proto.Bytes.toBase64) fastRawBytes)
        (rawBytes >> D.map (Tuple.mapSecond Proto.Bytes.toBase64))
        (\text -> writeBytes (Maybe.withDefault Proto.Bytes.empty (Proto.Bytes.fromBase64 text)))
        String.isEmpty
        ""


{-| `bytes` held as `Bytes`, under `bytes=bytes`.
-}
bytesAsBytes : Codec Bytes
bytesAsBytes =
    delimitedScalar fastRawBytes rawBytes writeBytes (\b -> Bytes.width b == 0) Proto.Bytes.empty


{-| An enum, from its generated number conversions: a number it does not
know reads as its zero value.
-}
enum : (a -> Int) -> (Int -> a) -> Codec a
enum toNumber fromNumber =
    scalarRun (varintRun (\n -> fromNumber (signed32 n)))
        0
        10
        (fastVarint32Map (\n -> fromNumber (signed32 n)))
        (fromVarint32 (\n -> fromNumber (signed32 n)) (fromNumber 0))
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
        readInto existing bound =
            varint32 bound
                |> D.andThen
                    (\( width, length ) ->
                        if width < 0 then
                            D.succeed (Err (leaf width))

                        else if length > bound - width then
                            D.succeed (Err pastEnd)

                        else
                            D.map
                                (\result ->
                                    case result of
                                        Ok v ->
                                            Ok ( width + length, v )

                                        Err failure ->
                                            Err (Internal.crossed width failure)
                                )
                                (run (into existing) length)
                    )

        fastInto existing =
            fastVarint32 |> D.andThen (\( width, length ) -> D.map (\v -> ( width + length, v )) (fastRun (into existing) length))

        name () =
            case into zero of
                Internal.Decoder d ->
                    d.name
    in
    Codec
        { wire = 2
        , fast = fastInto zero
        , fastBody = \length -> fastRun (into zero) length
        , fastInto = fastInto
        , read = readInto zero
        , write = \v -> delimited (write v)
        , isDefault = \_ -> False
        , zero = zero
        , packable = False
        , run = Nothing
        , writeBody = write
        , readBody = \length -> run (into zero) length
        , readInto = readInto
        , name = name
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
    Internal.Decoder { name = c.name (), fast = c.fastBody, located = c.readBody }



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
    wellKnown "google.protobuf.Timestamp"
        ( seconds, (millis - seconds * 1000) * 1000000 )
        partsStep
        (\( s, nanos ) -> Time.millisToPosix (s * 1000 + floor (toFloat nanos / 1.0e6)))


{-| A well-known type's decoder from its full name, the value it starts
from, its step and how its fields become its value.
-}
wellKnown : String -> b -> (Int -> Int -> b -> Field b) -> (b -> a) -> Decoder a
wellKnown name start step finish =
    Internal.Decoder
        { name = name
        , fast = fastMessage start step identity >> D.map finish
        , located = message name start step identity >> D.map (Result.map finish)
        }


{-| A `Timestamp`'s or a `Duration`'s fields: `seconds` (1) and `nanos` (2).
-}
partsStep : Int -> Int -> ( Int, Int ) -> Field ( Int, Int )
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
    wellKnown "google.protobuf.Duration"
        ( parts.seconds, parts.nanos )
        partsStep
        (\( seconds, nanos ) -> Proto.Duration.fromParts seconds nanos)


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
        (merge "google.protobuf.FieldMask"
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
    embedded (\() -> nothing) (merge "google.protobuf.Empty" (\_ wire acc -> skip wire acc) identity) ()


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
    merge "google.protobuf.Struct"
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
    merge "google.protobuf.ListValue"
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
    merge "google.protobuf.Value"
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


{-| `google.protobuf.Any`, holding the packed message's binary, which
[`Proto.Any.unpack`](Proto-Any#unpack) decodes. One held as JSON alone,
which a [lenient](Proto-Registry#lenient) registry reads, is written as its
type URL alone: its message is lost ([`Proto.Any.bytes`](Proto-Any#bytes)
tells it first). One that arrives twice is merged field by field: the type
URL or the value the later one carries replaces the earlier one's.
-}
any : Codec Any
any =
    embedded writeAny anyInto InternalAny.empty


anyInto : Any -> Decoder Any
anyInto (InternalAny.Any start payload) =
    wellKnown "google.protobuf.Any"
        ( start, Maybe.withDefault "" (InternalAny.base64Of payload) )
        (\number wire ( url, current ) ->
            case number of
                1 ->
                    field string (\v -> ( v, current )) wire ( url, current )

                2 ->
                    field bytes (\v -> ( url, v )) wire ( url, current )

                _ ->
                    skip wire ( url, current )
        )
        (\( url, current ) -> InternalAny.Any url (InternalAny.Binary current))


writeAny : Any -> Encoder
writeAny (InternalAny.Any url payload) =
    -- An `Any` held as JSON alone has no binary to write: its type URL is
    -- written alone.
    E.sequence [ implicit string 1 url, implicit bytes 2 (Maybe.withDefault "" (InternalAny.base64Of payload)) ]


wrapper : String -> Codec v -> Codec v
wrapper name ((Codec c) as inner) =
    embedded (implicit inner 1)
        (merge name
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
    wrapper "google.protobuf.DoubleValue" double


{-| `google.protobuf.FloatValue` as its `Float`.
-}
floatValue : Codec Float
floatValue =
    wrapper "google.protobuf.FloatValue" float


{-| `google.protobuf.Int64Value` as decimal text.
-}
int64Value : Codec String
int64Value =
    wrapper "google.protobuf.Int64Value" int64


{-| `google.protobuf.Int64Value` as an `Int`.
-}
int64ValueAsInt : Codec Int
int64ValueAsInt =
    wrapper "google.protobuf.Int64Value" int64AsInt


{-| `google.protobuf.UInt64Value` as decimal text.
-}
uint64Value : Codec String
uint64Value =
    wrapper "google.protobuf.UInt64Value" uint64


{-| `google.protobuf.UInt64Value` as an `Int`.
-}
uint64ValueAsInt : Codec Int
uint64ValueAsInt =
    wrapper "google.protobuf.UInt64Value" uint64AsInt


{-| `google.protobuf.Int32Value` as its `Int`.
-}
int32Value : Codec Int
int32Value =
    wrapper "google.protobuf.Int32Value" int32


{-| `google.protobuf.UInt32Value` as its `Int`.
-}
uint32Value : Codec Int
uint32Value =
    wrapper "google.protobuf.UInt32Value" uint32


{-| `google.protobuf.BoolValue` as its `Bool`.
-}
boolValue : Codec Bool
boolValue =
    wrapper "google.protobuf.BoolValue" bool


{-| `google.protobuf.StringValue` as its `String`.
-}
stringValue : Codec String
stringValue =
    wrapper "google.protobuf.StringValue" string


{-| `google.protobuf.BytesValue` as base64 text.
-}
bytesValue : Codec String
bytesValue =
    wrapper "google.protobuf.BytesValue" bytes


{-| `google.protobuf.BytesValue` as `Bytes`.
-}
bytesValueAsBytes : Codec Bytes
bytesValueAsBytes =
    wrapper "google.protobuf.BytesValue" bytesAsBytes
