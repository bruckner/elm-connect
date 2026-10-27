"""H5's synthetic schema: one package of N messages of eight fields and ten
enums, as decisions.md's earlier synthetic package was (300 messages of
eight fields and ten enums), and a program that reaches every message's
decoder, JSON and/or binary as the codec option gives them.

    python3 spike/synth.py N CODEC OUTDIR

writes OUTDIR/proto/synth/v1/synth.proto and OUTDIR/app/{elm.json,src/Main.elm};
spike/h5.sh generates the Elm with the CLI and times `elm make`.
"""
import os, sys, json

n, codec, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]
os.makedirs(f'{out}/proto/synth/v1', exist_ok=True)
os.makedirs(f'{out}/app/src', exist_ok=True)
lines = ['syntax = "proto3";', '', 'package synth.v1;', '']
for e in range(10):
    lines += [f'enum Kind{e} {{', f'  KIND{e}_UNSPECIFIED = 0;', f'  KIND{e}_A = 1;', f'  KIND{e}_B = 2;', '}', '']
for i in range(n):
    ref = f'Msg{i - 1} parent = 8;' if i else 'string parent = 8;'
    lines += [
        f'message Msg{i} {{',
        '  string name = 1;',
        '  int32 count = 2;',
        '  int64 big = 3;',
        '  bool flag = 4;',
        '  double ratio = 5;',
        f'  Kind{i % 10} kind = 6;',
        '  repeated string tags = 7;',
        f'  {ref}',
        '}', '',
    ]
open(f'{out}/proto/synth/v1/synth.proto', 'w').write('\n'.join(lines))

runtime = os.path.abspath('spike/out-rev/d77e2f68/src')
app = {
    'type': 'application',
    'source-directories': ['src', '../generated', runtime],
    'elm-version': '0.19.2',
    'dependencies': {
        'direct': {'elm/bytes': '1.0.8', 'elm/core': '1.0.5', 'elm/http': '2.0.0', 'elm/json': '1.1.4', 'elm/time': '1.0.0'},
        'indirect': {'elm/file': '1.0.5'},
    },
    'test-dependencies': {'direct': {}, 'indirect': {}},
}
json.dump(app, open(f'{out}/app/elm.json', 'w'), indent=4)

uses = []
for i in range(n):
    if codec in ('json', 'both'):
        uses.append(f'json (Json.Decode.decodeString Synth.V1.decodeMsg{i} "{{}}")')
    if codec in ('binary', 'both'):
        uses.append(f'binary (Proto.Binary.decode Synth.V1.decodeMsg{i}Bytes empty)')
main = f'''port module Main exposing (main)

import Bytes exposing (Bytes)
import Bytes.Encode
import Json.Decode
import Proto.Binary
import Synth.V1


port out : Int -> Cmd msg


empty : Bytes
empty =
    Bytes.Encode.encode (Bytes.Encode.sequence [])


json : Result e a -> Int
json r =
    case r of
        Ok _ ->
            1

        Err _ ->
            0


binary : Maybe a -> Int
binary r =
    case r of
        Just _ ->
            1

        Nothing ->
            0


main : Program () () ()
main =
    Platform.worker
        {{ init = \\_ -> ( (), out (List.sum [ {(chr(10) + "            , ").join(uses)} ]) )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }}
'''
open(f'{out}/app/src/Main.elm', 'w').write(main)
