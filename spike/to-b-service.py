"""Rewrite a gen-routes-2 service module (route functions, `methodWith`,
`descriptor*` as endpoints and `fullDescriptor*` as the cold form) into
Alternative B's generated shape by hand-written rules: `Proto.Method.json`
plus `withRoutes`, `endpoint*` values, `descriptor*` built from them,
`Proto.Route` helpers, calls typed `Rpc.Call Rpc.Json`.

    python3 spike/to-b-service.py IN.elm OUT.elm [HEADER-LINE]

This stands in for the generator change the spike does not build.
"""
import re, sys

src = open(sys.argv[1]).read()
header = sys.argv[3] if len(sys.argv) > 3 else None
s = src
if header:
    first = s.index('\n')
    s = s[:first + 1] + header + '\n' + s[first + 1:]
s = s.replace('import Rpc.Route\n', '')
s = s.replace('import Proto.Method\n', 'import Proto.Method\nimport Proto.Route\n') if 'Rpc.Route.Route' in src else s
s = s.replace('Proto.Version.v0_1', 'Proto.Version.v0_2')
s = s.replace('Rpc.Route.', 'Proto.Route.')
# Calls typed by codec.
s = re.sub(r'-> Rpc\.Call (?!Rpc\.)', '-> Rpc.Call Rpc.Json ', s)
# methodWith ENC DEC descriptorX [ routes ] -> json ENC DEC endpointX |> withRoutes [ routes ]
def method(m):
    indent, enc, dec, name, routes = m.group(1), m.group(2), m.group(3), m.group(4), m.group(5)
    routes_list = [r.strip() for r in routes.strip().strip('[]').split(',') if r.strip()]
    out = f'{indent}(Proto.Method.json {enc}\n{indent}    {dec}\n{indent}    endpoint{name}'
    if routes_list:
        out += f'\n{indent}    |> Proto.Method.withRoutes [ ' + ', '.join(routes_list) + ' ]'
    return out + f'\n{indent})'
s = re.sub(r'( +)\(Proto\.Method\.methodWith (\S+)\n\s+(\S+)\n\s+descriptor(\w+)\n\s+(\[[^\]]*\])\n\s+\)', method, s)
s = s.replace('\nDescribed by [`descriptor', '\nCodecs: JSON. Described by [`descriptor')
# Endpoints: descriptorX = Proto.Method.endpoint ... -> endpointX : Proto.Method.Endpoint
s = re.sub(r'\ndescriptor(\w+) : Proto\.Method\.Descriptor\ndescriptor\1 =\n    Proto\.Method\.endpoint ',
           r'\nendpoint\1 : Proto.Method.Endpoint\nendpoint\1 =\n    Proto.Method.endpoint ', s)
# Full descriptors: fullDescriptorX = Proto.Method.descriptor svc name idem in out [..]
s = re.sub(r'\nfullDescriptor(\w+) : Proto\.Method\.Descriptor\nfullDescriptor\1 =\n    Proto\.Method\.descriptor "[^"]*"\n\s+"[^"]*"\n\s+Proto\.Method\.\w+\n',
           r'\ndescriptor\1 : Proto.Method.Descriptor\ndescriptor\1 =\n    Proto.Method.descriptor endpoint\1\n', s)
s = s.replace('{-| The full descriptor of [', '{-| The descriptor of [')
s = s.replace('\n-- DESCRIPTORS\n', '\n-- ENDPOINTS AND DESCRIPTORS\n')
open(sys.argv[2], 'w').write(s)
