"""Attribute an unminified `elm make --optimize` output of the comparison
harness: elm-connect's runtime (Proto.*/Rpc.* of the package), elm-connect's
generated corpus (Codec.*), protoc-gen-elm's generated corpus
(Proto.Codec.*, Proto.Google.*), the harness, and each package.

    python3 compare-attr.py elm.js
"""
import re, sys, collections

src = open(sys.argv[1]).read()
parts = re.split(r'\nvar (\$[A-Za-z0-9_$]+)\s*=', src)
sizes = collections.Counter()
for i in range(1, len(parts), 2):
    name = parts[i]
    n = len(name) + len(parts[i + 1]) + 6
    seg = name.split('$')[1:]
    if seg[0] == 'author':
        mods = seg[2:-1]
        if mods[:2] in (['Proto', 'Codec'], ['Proto', 'Google']):
            key = 'generated: protoc-gen-elm'
        elif mods[:1] == ['Codec']:
            key = 'generated: elm-connect'
        elif mods[:1] in (['Proto'], ['Rpc']):
            key = 'runtime: elm-connect ' + '.'.join(mods[:2])
        else:
            key = 'harness'
    else:
        key = 'package: ' + seg[0] + '/' + seg[1]
    sizes[key] += n
for k, v in sorted(sizes.items(), key=lambda kv: -kv[1]):
    print(f"  {k:48} {v:8}")
print(f"  {'total':48} {sum(sizes.values()):8}")
