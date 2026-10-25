"""Per definition: new in AFTER, or changed in size, against BEFORE.

    python3 defdiff2.py before.js after.js [MIN]
"""
import re, sys
def defs(path):
    src = open(path).read()
    parts = re.split(r'\nvar (\$[A-Za-z0-9_$]+)\s*=', src)
    return {parts[i]: len(parts[i]) + len(parts[i + 1]) + 6 for i in range(1, len(parts), 2)}
a, b = defs(sys.argv[1]), defs(sys.argv[2])
low = int(sys.argv[3]) if len(sys.argv) > 3 else 5
rows = [(n, 'new', k) for k, n in b.items() if k not in a]
rows += [(b[k] - a[k], 'changed', k) for k in b if k in a and abs(b[k] - a[k]) >= low]
rows += [(-n, 'gone', k) for k, n in a.items() if k not in b]
for n, kind, k in sorted(rows, key=lambda r: -abs(r[0])):
    print(f"{n:7} {kind:8} {k}")
print("net", sum(r[0] for r in rows))
