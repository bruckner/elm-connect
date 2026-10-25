"""Attribute the bytes of an unminified `elm make --optimize` output to
modules: runtime (the package's Rpc.* and Proto.* modules), generated (the
module prefixes given), app (every other module of the project) and the
packages it depends on.

    python3 attr.py elm.js GEN1,GEN2 [TOP] [full]

GEN1,GEN2 are the first segments of generated modules (`Notes`, `Routes`).
Adapted from the review's attribution script; only the classification of
generated modules is now an argument. With `full`, runtime modules are keyed
by their whole name (`Rpc.Internal.Answer`) rather than the first two segments.
"""
import re, sys, collections

src = open(sys.argv[1]).read()
generated = set(sys.argv[2].split(',')) if len(sys.argv) > 2 else set()
top = int(sys.argv[3]) if len(sys.argv) > 3 else 25
full = len(sys.argv) > 4 and sys.argv[4] == 'full'
parts = re.split(r'\nvar (\$[A-Za-z0-9_$]+)\s*=', src)
sizes = collections.Counter()
for i in range(1, len(parts), 2):
    name = parts[i]; body = parts[i + 1]; n = len(name) + len(body) + 6
    seg = name.split('$')[1:]  # author, project, Module..., fn
    if seg[0] == 'author':
        mods = seg[2:-1]
        if mods[:1] in (['Rpc'], ['Proto']):
            key = 'runtime:' + '.'.join(mods if full else mods[:2])
        elif mods[:1] and mods[0] in generated:
            key = 'generated:' + '.'.join(mods[:3])
        else:
            key = 'app:' + mods[0] if mods else 'app:?'
    else:
        key = 'pkg:' + seg[0] + '/' + seg[1]
    sizes[key] += n
tot = sum(sizes.values())
groups = collections.Counter()
for k, v in sizes.items():
    groups[k.split(':')[0]] += v
print("total attributed", tot)
for g, v in groups.most_common():
    print(f"  {g:10} {v:9}")
print("--- top keys")
for k, v in sizes.most_common(top):
    print(f"  {k:40} {v:8}")
