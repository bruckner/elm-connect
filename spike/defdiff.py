"""Definitions present in one `elm make --optimize` output and not in the
other, with their bytes, grouped by module:

    python3 defdiff.py before.js after.js [TOP]
"""
import re, sys, collections

def defs(path):
    src = open(path).read()
    parts = re.split(r'\nvar (\$[A-Za-z0-9_$]+)\s*=', src)
    return {parts[i]: len(parts[i]) + len(parts[i + 1]) + 6 for i in range(1, len(parts), 2)}

a, b = defs(sys.argv[1]), defs(sys.argv[2])
top = int(sys.argv[3]) if len(sys.argv) > 3 else 40
for label, x, y in (("only in after", b, a), ("only in before", a, b)):
    mods = collections.Counter()
    for k, n in x.items():
        if k not in y:
            mods['$'.join(k.split('$')[:-1])] += n
    print(f"== {label}: {sum(mods.values())} B")
    for k, n in mods.most_common(top):
        print(f"  {k:60} {n:7}")
