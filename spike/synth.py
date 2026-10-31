"""H5's synthetic schema: one package of N messages of eight fields and ten
enums, as decisions.md's earlier synthetic package was (300 messages of
eight fields and ten enums), and a program that reaches every message's
decoder, JSON and/or binary as the codec option gives them.

    python3 spike/synth.py N CODEC OUTDIR [PACKAGES]

writes OUTDIR/proto/<pkg>/v1/<pkg>.proto for each of PACKAGES packages
(default 1, named `synth`; with several, `synth0`, `synth1`, ... of N
messages each, with no references between them) and
OUTDIR/app/{elm.json,src/Main.elm}. CODEC is json, binary or both (the CLI
spells binary `proto`); spike/gen.sh generates the Elm with the CLI and
spike/make.sh times `elm make`.

Message i's `parent` is message i - 1, so the package is one chain of N
nested types; SYNTH_PARENT=root points every one at Msg0 and
SYNTH_PARENT=chainK starts a new chain at every K-th message.
"""
import os, sys, json

n, codec, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]
packages = int(sys.argv[4]) if len(sys.argv) > 4 else 1
shape = os.environ.get('SYNTH_PARENT', 'chain')


def parent(i):
    if shape == 'root':
        return 0
    if shape.startswith('chain') and shape != 'chain':
        k = int(shape[5:])
        return i - 1 if i % k else 0
    return i - 1


names = ['synth'] if packages == 1 else [f'synth{k}' for k in range(packages)]
os.makedirs(f'{out}/app/src', exist_ok=True)
def proto(pkg):
  lines = ['syntax = "proto3";', '', f'package {pkg}.v1;', '']
  for e in range(10):
      lines += [f'enum Kind{e} {{', f'  KIND{e}_UNSPECIFIED = 0;', f'  KIND{e}_A = 1;', f'  KIND{e}_B = 2;', '}', '']
  for i in range(n):
      ref = f'Msg{parent(i)} parent = 8;' if i else 'string parent = 8;'
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
  return '\n'.join(lines)
for pkg in names:
    os.makedirs(f'{out}/proto/{pkg}/v1', exist_ok=True)
    open(f'{out}/proto/{pkg}/v1/{pkg}.proto', 'w').write(proto(pkg))

runtime = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src'))
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
mods = [p[0].upper() + p[1:] + '.V1' for p in names]
for m in mods:
  for i in range(n):
    if codec in ('json', 'both'):
        uses.append(f'json (Json.Decode.decodeString {m}.decodeMsg{i} "{{}}")')
    if codec in ('binary', 'both'):
        uses.append(f'binary (Proto.Binary.decode {m}.decodeMsg{i}Bytes empty)')
main = f'''port module Main exposing (main)

import Bytes exposing (Bytes)
import Bytes.Encode
import Json.Decode
import Proto.Binary
{chr(10).join('import ' + m for m in mods)}


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
