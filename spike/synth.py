"""A synthetic schema: one package of N messages of eight fields and ten
enums, and a program that reaches every message's decoder, JSON and/or
binary as CODEC says (json, binary or both).

    python3 spike/synth.py N CODEC OUTDIR

writes OUTDIR/proto/synth/v1/synth.proto and OUTDIR/app/{elm.json,
src/Main.elm}. Message i's `parent` is message i - 1, so the package is one
chain of N nested types; SYNTH_PARENT=chainK starts a new chain at every
K-th message (chain1: every message's parent is Msg0). SYNTH_ANY=1 gives
Msg0 a `google.protobuf.Any extra = 9`. RUNTIME names the runtime's src
directory the program compiles against (default: this worktree's).
"""
import os, sys, json

n, codec, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]
shape = os.environ.get('SYNTH_PARENT', 'chain')
with_any = os.environ.get('SYNTH_ANY') == '1'


def parent(i):
    if shape.startswith('chain') and shape != 'chain':
        k = int(shape[5:])
        return i - 1 if i % k else 0
    return i - 1


os.makedirs(f'{out}/app/src', exist_ok=True)
os.makedirs(f'{out}/proto/synth/v1', exist_ok=True)
lines = ['syntax = "proto3";', '', 'package synth.v1;', '']
if with_any:
    lines += ['import "google/protobuf/any.proto";', '']
for e in range(10):
    lines += [f'enum Kind{e} {{', f'  KIND{e}_UNSPECIFIED = 0;', f'  KIND{e}_A = 1;', f'  KIND{e}_B = 2;', '}', '']
for i in range(n):
    ref = f'Msg{parent(i)} parent = 8;' if i else 'string parent = 8;'
    extra = ['  google.protobuf.Any extra = 9;'] if with_any and i == 0 else []
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
        *extra,
        '}', '',
    ]
open(f'{out}/proto/synth/v1/synth.proto', 'w').write('\n'.join(lines))

runtime = os.environ.get('RUNTIME') or os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src'))
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
