"""Unminified bytes of the generated codecs per message of an `elm make
--optimize` output: each `encode*`/`decode*` definition of a generated module,
grouped by the message it belongs to (the name without the direction, a
`Bytes` suffix, and a oneof's or boxed type's suffix found among the
message names given), JSON and binary apart.

    python3 permsg.py elm.js Scalars,Optionals,...
"""
import re, sys, collections

src = open(sys.argv[1]).read()
names = sorted(sys.argv[2].split(','), key=len, reverse=True)
parts = re.split(r'\nvar (\$[A-Za-z0-9_$]+)\s*=', src)
table = collections.defaultdict(lambda: collections.Counter())
for i in range(1, len(parts), 2):
    name = parts[i]; n = len(name) + len(parts[i + 1]) + 6
    seg = name.split('$')[1:]
    if seg[0] != 'author' or 'Generated' not in seg:
        continue
    fn = seg[-1]
    m = re.match(r'(encode|decode)(.*)', fn)
    if not m:
        continue
    rest = m.group(2)
    kind = 'binary' if rest.endswith('Bytes') else 'json'
    if kind == 'binary':
        rest = rest[:-5]
    owner = next((x for x in names if rest.startswith(x)), 'other')
    table[owner][kind] += n
print('| message | JSON | binary |')
print('|---|---:|---:|')
for owner in sorted(table):
    print(f"| {owner} | {table[owner]['json']} | {table[owner]['binary']} |")
print(f"| total | {sum(t['json'] for t in table.values())} | {sum(t['binary'] for t in table.values())} |")
