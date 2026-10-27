"""§8.1's alternative to routes on the method, the comparison build for H3:
`Rpc.Protocol.transcode` takes the route tables of the services it
transcodes (`transcode [ Notes.V1.NotesService.routes ]`); a method carries
its endpoint and codecs only. A table maps `service/method` to the method's
bindings as `Proto.Http` data, read per call by the interpreter, so the
protocol stays data (R2) and `==` holds. The method's call cannot check
`viaBinding` against its routes any more, so it always accepts the index;
a method the tables lack goes over the implicit route. Applied to a copy
by spike/variant.sh."""
import sys, re
root = sys.argv[1]

def edit(path, pairs):
    p = f'{root}/{path}'
    s = open(p).read()
    for old, new in pairs:
        if old not in s:
            raise SystemExit(f'{path}: not found: {old[:70]!r}')
        s = s.replace(old, new)
    open(p, 'w').write(s)

edit('src/Proto/Http.elm', [
    ('    , Param, param\n', '    , Param, param\n    , Table, table\n'),
    ('import Proto.Enum\n', 'import Dict exposing (Dict)\nimport Proto.Enum\n'),
])
p = f'{root}/src/Proto/Http.elm'
s = open(p).read()
s = s.replace('@docs Param, param\n', '@docs Param, param\n\n\n# Route tables\n\n@docs Table, table\n', 1)
s += '''

{-| A service's routes for transcoding: each method's bindings, by
`service/method`. Generated code writes one per service (`routes`).
-}
type alias Table =
    Dict String (List Binding)


{-| A table from its methods' bindings.
-}
table : List ( String, List Binding ) -> Table
table =
    Dict.fromList
'''
open(p, 'w').write(s)

edit('src/Rpc/Internal/Protocol.elm', [
    ('import Proto.Method exposing (Endpoint)\n', 'import Dict exposing (Dict)\nimport Proto.Http exposing (Binding)\nimport Proto.Method exposing (Endpoint)\n'),
    ('        , options : Options\n        , wire : Wire\n', '        , options : Options\n        , routes : Dict String (List Binding)\n        , wire : Wire\n'),
    ('    , routed : Bool\n', '    , routed : Bool\n    , route : Dict String (List Binding) -> String -> Int -> Value -> Maybe Route\n'),
])
edit('src/Rpc/Internal/Wire.elm', [
    ('    , usableTimeout\n', '    , usableTimeout, tableRoute, noRoute\n'),
    ('import Json.Encode exposing (Value)\n', 'import Dict exposing (Dict)\nimport Json.Encode exposing (Value)\nimport Proto.Http exposing (Binding)\nimport Proto.Internal.Binding\nimport Proto.Internal.Interpret\n'),
])
p = f'{root}/src/Rpc/Internal/Wire.elm'
s = open(p).read()
s += '''

{-| A call's route from the protocol's tables: its method's binding of that
number, read from the request's JSON by the interpreter.
-}
tableRoute : Dict String (List Binding) -> String -> Int -> Value -> Maybe Route
tableRoute tables key index json =
    Dict.get key tables
        |> Maybe.andThen (List.drop index >> List.head)
        |> Maybe.map (\\(Proto.Internal.Binding.Binding rule) -> Proto.Internal.Interpret.route rule json)


{-| No routes, for a protocol that reads none.
-}
noRoute : Dict String (List Binding) -> String -> Int -> Value -> Maybe Route
noRoute _ _ _ _ =
    Nothing
'''
open(p, 'w').write(s)

p = f'{root}/src/Rpc/Protocol.elm'
s = open(p).read()
s = s.replace('import Json.Encode exposing (Value)\n', 'import Dict\nimport Json.Encode exposing (Value)\nimport Proto.Http\n')
s = s.replace('        , options = noOptions\n', '        , options = noOptions\n        , routes = Dict.empty\n')
s = s.replace('                , routed = False\n', '                , routed = False\n                , route = Wire.noRoute\n')
s = s.replace('                , routed = True\n', '                , routed = True\n                , route = Wire.tableRoute\n')
s = s.replace('transcode : Protocol Json\ntranscode =\n', 'transcode : List Proto.Http.Table -> Protocol Json\ntranscode tables =\n')
i = s.index('transcode tables =')
j = s.index('        , routes = Dict.empty\n', i)
s = s[:j] + '        , routes = List.foldl Dict.union Dict.empty tables\n' + s[j + len('        , routes = Dict.empty\n'):]
open(p, 'w').write(s)

p = f'{root}/src/Rpc/Internal/Send.elm'
s = open(p).read()
old = '''                        route =
                            if wire.routed then
                                List.head (List.drop c.binding m.routes)
                                    |> Maybe.map (\\routeOf -> routeOf c.message)

                            else
                                Nothing
'''
new = '''                        route =
                            if wire.routed then
                                wire.route p.routes (Proto.Method.service m.endpoint ++ "/" ++ Proto.Method.name m.endpoint) c.binding (json ())

                            else
                                Nothing
'''
assert old in s
s = s.replace(old, new)
s = s.replace('import Proto.Route exposing (PathError)\n', 'import Proto.Method\nimport Proto.Route exposing (PathError)\n')
open(p, 'w').write(s)

edit('src/Rpc/Call.elm', [
    ('    if index >= 0 && index < routeCount c.method then', '    if index >= 0 then'),
])

# Generated notes service: no routes on the method, a table instead.
p = f'{root}/examples/notes/elm/generated/Notes/V1/NotesService.elm'
s = open(p).read()
s = re.sub(r'\n\s*\|> Proto\.Method\.withRoutes \[[^\]]*\]', '', s)
i = s.index('\n-- ROUTES\n')
j = s.index('\n-- ENDPOINTS AND DESCRIPTORS\n')
entries = []
for m in re.finditer(r'\ndescriptor(\w+) =\n    Proto\.Method\.descriptor endpoint\1\n\s+"[^"]*"\n\s+"[^"]*"\n((?:        .*\n)+)', s):
    name, bindings = m.group(1), m.group(2)
    entries.append((name, bindings))
table = '\n-- ROUTES\n\n\n{-| The service\'s routes for transcoding: `Rpc.Protocol.transcode [ routes ]`.\n-}\nroutes : Proto.Http.Table\nroutes =\n    Proto.Http.table\n        [ '
parts = []
for name, bindings in entries:
    b = bindings.rstrip('\n')
    b = '\n'.join('    ' + l if l.strip() else l for l in b.split('\n'))
    parts.append(f'( "notes.v1.NotesService/{name}"\n          ,{b[11:]}\n          )')
table += '\n        , '.join(parts) + '\n        ]\n\n\n'
s = s[:i] + table + s[j:]
open(p, 'w').write(s)

for main in ['examples/notes/elm/src/Main.elm']:
    p = f'{root}/{main}'
    s = open(p).read()
    s = s.replace('Rpc.Protocol.transcode', '(Rpc.Protocol.transcode [ Notes.routes ])')
    open(p, 'w').write(s)
