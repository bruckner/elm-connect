"""Write M3's Bench.elm for one build: `142` (#142 under codec=json, an Any
held as its JSON) or `base` (this branch under codec=json, an Any held as
its binary, the JSON converted through Bench.V1.registry).

    python3 spike/m3/bench.py 142|base OUT.elm

Flags `{ task, n }`; `init` runs the task n times and sends a checksum on
the port `done`, as spike/m3/bench.js times it. Tasks: decode.any,
encode.any, unpack.any, decode.plain, encode.plain.
"""
import json, os, sys

build, out = sys.argv[1], sys.argv[2]
fx = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fixtures.json')))
lit = lambda s: json.dumps(s)

if build == '142':
    decode_any = 'Bench.V1.decodeEnvelope'
    encode_any = 'Bench.V1.encodeEnvelope env'
    unpack = 'Proto.Any.unpackJson Bench.V1.messagePayload'
else:
    decode_any = 'Bench.V1.decodeEnvelope'
    encode_any = 'Result.withDefault Json.Encode.null (Bench.V1.encodeEnvelopeWith Bench.V1.registry env)'
    unpack = 'Proto.Any.unpack Bench.V1.messagePayload'

src = f'''port module Bench exposing (main)

import Bench.V1
import Json.Decode
import Json.Encode
import Proto.Any


port done : String -> Cmd msg


envelopeJson : String
envelopeJson =
    {lit(fx["envelope"])}


plainJson : String
plainJson =
    {lit(fx["plain"])}


envelope : Bench.V1.Envelope
envelope =
    Json.Decode.decodeString {decode_any} envelopeJson
        |> Result.withDefault Bench.V1.defaultEnvelope


plain : Bench.V1.Plain
plain =
    Json.Decode.decodeString Bench.V1.decodePlain plainJson
        |> Result.withDefault Bench.V1.defaultPlain


encodeEnvelope : Bench.V1.Envelope -> String
encodeEnvelope env =
    Json.Encode.encode 0 ({encode_any})


loop : Int -> (Int -> Int) -> Int -> Int
loop n f acc =
    if n <= 0 then
        acc

    else
        loop (n - 1) f (acc + f n)


ok : Result e a -> Int
ok r =
    case r of
        Ok _ ->
            1

        Err _ ->
            0


task : String -> Int -> Int
task name _ =
    case name of
        "decode.any" ->
            ok (Json.Decode.decodeString {decode_any} envelopeJson)

        "encode.any" ->
            String.length (encodeEnvelope envelope)

        "unpack.any" ->
            case Maybe.andThen ({unpack}) envelope.payload of
                Just p ->
                    String.length p.body

                Nothing ->
                    0

        "decode.plain" ->
            ok (Json.Decode.decodeString Bench.V1.decodePlain plainJson)

        "encode.plain" ->
            String.length (Json.Encode.encode 0 (Bench.V1.encodePlain plain))

        "check" ->
            if envelope.id == "" || plain.id == "" || envelope.payload == Nothing || plain.payload == Nothing then
                1

            else
                0

        _ ->
            0


main : Program {{ task : String, n : Int }} () ()
main =
    Platform.worker
        {{ init = \\flags -> ( (), done (String.fromInt (loop flags.n (task flags.task) 0)) )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }}
'''
open(out, 'w').write(src)
