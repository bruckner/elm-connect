module Proto.Query exposing (string, int, int64, bool, float, enum, optional, repeated, unlessZero, except)

{-| The query parameters of a binding, as a generated `queryOf<Message>`
function in a package module writes them from a typed message: one helper
per field, each giving no parameter at the field's default.

@docs string, int, int64, bool, float, enum, optional, repeated, unlessZero, except

-}

import Json.Encode exposing (Value)
import Proto.Route


{-| A query parameter of a field without presence, by its name, its proto3
default and its text: none at the default.
-}
unlessZero : String -> a -> (a -> String) -> a -> List ( String, String )
unlessZero name zero toText value =
    if value == zero then
        []

    else
        [ ( name, toText value ) ]


{-| A `string` or `bytes` field's parameter: none at `""`.
-}
string : String -> String -> List ( String, String )
string name value =
    if value == "" then
        []

    else
        [ ( name, value ) ]


{-| A 32-bit integer field's parameter: none at 0.
-}
int : String -> Int -> List ( String, String )
int name value =
    if value == 0 then
        []

    else
        [ ( name, String.fromInt value ) ]


{-| A 64-bit integer field's parameter, held as its decimal string: none at
`"0"`.
-}
int64 : String -> String -> List ( String, String )
int64 name value =
    if value == "0" then
        []

    else
        [ ( name, value ) ]


{-| A boolean field's parameter: none at `False`.
-}
bool : String -> Bool -> List ( String, String )
bool name value =
    if value then
        [ ( name, "true" ) ]

    else
        []


{-| A floating-point field's parameter, as proto3 JSON writes it (`NaN`,
`Infinity`, `-Infinity` included): none at 0.
-}
float : String -> Float -> List ( String, String )
float name value =
    -- Not `value == 0`, which compiles to `!value` and so drops NaN.
    if value /= 0 || isNaN value then
        [ ( name, String.fromFloat value ) ]

    else
        []


{-| An enum field's parameter, by its zero and its encoder: none at the zero.
-}
enum : String -> e -> (e -> Value) -> e -> List ( String, String )
enum name zero encode value =
    if value == zero then
        []

    else
        [ ( name, Proto.Route.jsonText (encode value) ) ]


{-| A parameter of a field with presence, as text: none when unset.
-}
optional : String -> Maybe String -> List ( String, String )
optional name value =
    case value of
        Just v ->
            [ ( name, v ) ]

        Nothing ->
            []


{-| A repeated field's parameters, as text: one per element.
-}
repeated : String -> List String -> List ( String, String )
repeated name values =
    List.map (Tuple.pair name) values


{-| A message's query parameters without those of the named fields: a
binding's query, from its request message's query encoder less the fields
its path and body hold.
-}
except : List String -> List ( String, String ) -> List ( String, String )
except names pairs =
    List.filter (\( name, _ ) -> not (List.member name names)) pairs
