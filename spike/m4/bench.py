"""Write M4b's and M4e's Bench.elm: one source for every runtime (the base,
the cache, the lenient registry, the base with one request encode), since
the tasks use no name those runtimes differ in.

    python3 spike/m4/bench.py OUT.elm

Flags `{ task, n }`; `init` runs the task n times and sends a checksum on
the port `done`, as spike/m4/bench.js times it. The Any read from JSON
(`envelope`) holds its JSON beside its binary under the cache; `bare` is
the same envelope with its Any written to binary and read back, so it holds
the binary alone under every runtime.
"""
import json, os, sys

out = sys.argv[1]
fx = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'm3', 'fixtures.json')))
lit = lambda s: json.dumps(s)

src = f'''port module Bench exposing (main)

import Bench.V1
import Json.Decode
import Json.Encode
import Proto.Any
import Proto.Binary
import Proto.Method
import Rpc
import Rpc.Protocol


port done : String -> Cmd msg


envelopeJson : String
envelopeJson =
    {lit(fx["envelope"])}


plainJson : String
plainJson =
    {lit(fx["plain"])}


envelope : Bench.V1.Envelope
envelope =
    Json.Decode.decodeString Bench.V1.decodeEnvelope envelopeJson
        |> Result.withDefault Bench.V1.defaultEnvelope


{{-| The envelope with its Any read back from binary.
-}}
bare : Bench.V1.Envelope
bare =
    {{ envelope | payload = Maybe.andThen throughBinary envelope.payload }}


throughBinary : Proto.Any.Any -> Maybe Proto.Any.Any
throughBinary any =
    Proto.Binary.decode (Proto.Binary.messageDecoder Proto.Binary.any) (Proto.Binary.encode (Proto.Binary.messageEncoder Proto.Binary.any) any)


payload : Bench.V1.Payload
payload =
    Maybe.andThen (Proto.Any.unpack Bench.V1.messagePayload) bare.payload
        |> Maybe.withDefault Bench.V1.defaultPayload


plain : Bench.V1.Plain
plain =
    Json.Decode.decodeString Bench.V1.decodePlain plainJson
        |> Result.withDefault Bench.V1.defaultPlain


encodeEnvelope : Bench.V1.Envelope -> String
encodeEnvelope env =
    Json.Encode.encode 0 (Result.withDefault Json.Encode.null (Bench.V1.encodeEnvelopeWith Bench.V1.registry env))


client : Rpc.Client Rpc.Json
client =
    Rpc.client Rpc.Protocol.connect "https://api.example.com"


{{-| A JSON-wired method sending an Envelope, binding the package's table,
as generated code binds it for a method whose request reaches an Any.
-}}
sendEnvelope : Bench.V1.Envelope -> Rpc.Call Rpc.Json Bench.V1.Envelope Bench.V1.Envelope
sendEnvelope =
    Rpc.call (Proto.Method.initJson "bench.v1.Svc" "Put" Bench.V1.registry Bench.V1.encodeEnvelopeWith Bench.V1.decodeEnvelopeWith)


sendPlain : Bench.V1.Plain -> Rpc.Call Rpc.Json Bench.V1.Plain Bench.V1.Plain
sendPlain =
    Rpc.call (Proto.Method.initJson "bench.v1.Svc" "PutPlain" Bench.V1.registry (\\_ -> Ok << Bench.V1.encodePlain) (\\_ -> Bench.V1.decodePlain))


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


unpacked : Bench.V1.Envelope -> Int
unpacked env =
    case Maybe.andThen (Proto.Any.unpack Bench.V1.messagePayload) env.payload of
        Just p ->
            String.length p.body

        Nothing ->
            0


task : String -> Int -> Int
task name _ =
    case name of
        "decode.any" ->
            ok (Json.Decode.decodeString Bench.V1.decodeEnvelope envelopeJson)

        "encode.any" ->
            String.length (encodeEnvelope envelope)

        "encode.bare" ->
            String.length (encodeEnvelope bare)

        "unpack.any" ->
            unpacked envelope

        "unpack.bare" ->
            unpacked bare

        "pack" ->
            if Proto.Any.typeUrl (Proto.Any.pack Bench.V1.messagePayload payload) == "" then
                0

            else
                1

        "send.any" ->
            List.length [ Rpc.send client (\\_ -> ()) (sendEnvelope envelope) ]

        "send.bare" ->
            List.length [ Rpc.send client (\\_ -> ()) (sendEnvelope bare) ]

        "send.plain" ->
            List.length [ Rpc.send client (\\_ -> ()) (sendPlain plain) ]

        "decode.plain" ->
            ok (Json.Decode.decodeString Bench.V1.decodePlain plainJson)

        "encode.plain" ->
            String.length (Json.Encode.encode 0 (Bench.V1.encodePlain plain))

        "check" ->
            if envelope.id == "" || plain.id == "" || envelope.payload == Nothing || bare.payload == Nothing || payload.body == "" || unpacked envelope /= unpacked bare then
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
