"""Bytes of an unminified `elm make --optimize` output that are codecs:
the generated encoders and decoders (definitions of a generated module
whose name starts with `encode` or `decode`), and the runtime's codec
modules (Proto.Json, Proto.Binary), each module's total.

    python3 codecs.py elm.js
"""
import re, sys, collections

src = open(sys.argv[1]).read()
parts = re.split(r'\nvar (\$[A-Za-z0-9_$]+)\s*=', src)
generated = collections.Counter()
runtime = collections.Counter()
for i in range(1, len(parts), 2):
    name = parts[i]; n = len(name) + len(parts[i + 1]) + 6
    seg = name.split('$')[1:]
    if seg[0] != 'author':
        continue
    mods, fn = seg[2:-1], seg[-1]
    if mods[:2] in (['Proto', 'Json'], ['Proto', 'Binary']):
        runtime['.'.join(mods[:2])] += n
    elif mods and mods[0] in ('Notes', 'Google', 'Routes', 'Generated') and fn.startswith(('encode', 'decode')):
        kind = 'binary' if fn.endswith('Bytes') or '$Bytes' in name else 'json'
        generated[kind] += n
for k, v in sorted(generated.items()):
    print(f"  generated codecs ({k:6}) {v:8}")
for k, v in sorted(runtime.items()):
    print(f"  runtime {k:22} {v:8}")
