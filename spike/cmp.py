"""Compare two `elm make --optimize` outputs by module (attr2.py's keys) and,
with --defs, by definition: optimized bytes before, after, and the change.

    python3 spike/cmp.py BEFORE.js AFTER.js GEN1,GEN2 [--defs PREFIX]
"""
import sys, collections, importlib.util, os
spec = importlib.util.spec_from_file_location('attr2', os.path.join(os.path.dirname(__file__), 'attr2.py'))
src = open(spec.origin).read().replace('\nmain()\n', '\n')
attr2 = {}
exec(compile(src, spec.origin, 'exec'), attr2)

def load(path, gen):
    head, stmts, tail = attr2['split'](open(path).read())
    by_key, by_def = collections.Counter(), collections.Counter()
    for s in stmts:
        n = attr2['name_of'](s)
        by_key[attr2['key_of'](n, gen)] += len(s) + 1
        by_def[n or '?'] += len(s) + 1
    return by_key, by_def

gen = set(sys.argv[3].split(','))
a_key, a_def = load(sys.argv[1], gen)
b_key, b_def = load(sys.argv[2], gen)
prefix = sys.argv[sys.argv.index('--defs') + 1] if '--defs' in sys.argv else None
rows = a_def.keys() | b_def.keys() if prefix is not None else a_key.keys() | b_key.keys()
A, B = (a_def, b_def) if prefix is not None else (a_key, b_key)
out = []
for k in rows:
    if prefix is not None and prefix not in k:
        continue
    d = B[k] - A[k]
    if d:
        out.append((d, k))
for d, k in sorted(out):
    print(f"{A[k]:8} {B[k]:8} {d:+8}  {k}")
print(f"{sum(A.values()):8} {sum(B.values()):8} {sum(B.values()) - sum(A.values()):+8}  total")
