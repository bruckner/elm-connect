module Proto.Internal.Binary.Wire exposing
    ( U64(..)
    , delimited
    , fastFixed64
    , fastRawBytes
    , fastSkipValue
    , fastString
    , fastVarint32
    , fastVarint64
    , fieldKey
    , fixed
    , fixed64Read
    , fixed64Write
    , fromInt64
    , fromText
    , fromVarint32
    , rawBytes
    , signed32
    , signedText
    , skipValue
    , toInt64
    , toUInt64
    , unsignedText
    , unzigzag64
    , utf8String
    , varint32
    , varint64
    , writeBytes
    , writeInt32
    , writeVarint32
    , writeVarint64
    , zigzag64
    )

{-| The values of the protobuf binary wire format as bytes, below
`Proto.Binary`: how a varint, a fixed-width value, a length-delimited value
and a `string` are read and written, how a field's key is written and its
value skipped, and a 64-bit value held as two halves ([`U64`](#U64)) with
its arithmetic and its decimal text. Nothing here knows a codec, a field or
a message: `Proto.Binary` builds those from these, and is the one module
that imports this one.

Each read comes twice, as a decoder reads twice (`Proto.Internal.Binary`).
The fast one (`fastVarint32`, `fastString`) is a bare elm/bytes decoder
that fails without saying why. The other is given the bytes left in the
region it reads in, never reads past them, and gives the value's width, or
a negative width for a failure: -1 for a varint longer than ten bytes, -2
for a read past the bytes left, -4 for a `string` whose bytes are not
UTF-8. `Proto.Binary` turns the width into the failure (its `leaf`), and
gives -3 itself, for a value its holding cannot hold.

-}

import Bitwise
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D exposing (Step(..))
import Bytes.Encode as E exposing (Encoder)
import Proto.Bytes



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
    D.unsignedInt8
        |> D.andThen
            (\b ->
                if b < 128 then
                    D.succeed ( 1, b )

                else
                    D.loop ( 1, b - 128 ) fastVarint32Step
            )


fastVarint32Step : ( Int, Int ) -> D.Decoder (Step ( Int, Int ) ( Int, Int ))
fastVarint32Step ( index, low ) =
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


fastVarint64 : D.Decoder ( Int, U64 )
fastVarint64 =
    D.unsignedInt8
        |> D.andThen
            (\b ->
                if b < 128 then
                    D.succeed ( 1, U64 0 b )

                else
                    D.loop ( 1, 0, b - 128 ) fastVarint64Step
            )


fastVarint64Step : ( Int, Int, Int ) -> D.Decoder (Step ( Int, Int, Int ) ( Int, U64 ))
fastVarint64Step ( index, high, low ) =
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



-- LENGTH-DELIMITED VALUES


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


fastRawBytes : D.Decoder ( Int, Bytes )
fastRawBytes =
    fastVarint32 |> D.andThen (\( width, length ) -> D.map (\b -> ( width + length, b )) (D.bytes length))


rawBytes : Int -> D.Decoder ( Int, Bytes )
rawBytes =
    delimitedRead Proto.Bytes.empty D.bytes


writeBytes : Bytes -> Encoder
writeBytes b =
    E.sequence [ writeVarint32 (Bytes.width b), E.bytes b ]



-- STRINGS


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



-- FIELDS


fieldKey : Int -> Int -> Encoder
fieldKey number wire =
    writeVarint32 (number * 8 + wire)


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
