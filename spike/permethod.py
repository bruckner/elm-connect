"""Per-method bytes of a service module, before and after, from two
unminified `elm make --optimize` outputs: the call, its descriptor, and
(after) its route functions, summed per method.

    python3 spike/permethod.py BEFORE.js AFTER.js '$author$project$Notes$V1$NotesService$'
"""
import re, sys, collections

def defs(path, prefix):
    src = open(path).read()
    parts = re.split(r'\nvar (\$[A-Za-z0-9_$]+)\s*=', src)
    out = {}
    for i in range(1, len(parts), 2):
        name = parts[i]
        if name.startswith(prefix):
            out[name[len(prefix):]] = len(name) + len(parts[i + 1]) + 6
    return out

def per_method(d):
    m = collections.Counter()
    for k, v in d.items():
        k2 = re.sub(r'^(descriptor|route|bindings)', '', k)
        k2 = re.sub(r'\d+$', '', k2) if k.startswith('route') else k2
        m[k2[0].lower() + k2[1:]] += v
    return m

before = per_method(defs(sys.argv[1], sys.argv[3]))
after = per_method(defs(sys.argv[2], sys.argv[3]))
print(f"| method | before | after | delta |")
print(f"|---|---:|---:|---:|")
for k in sorted(set(before) | set(after)):
    b, a = before.get(k, 0), after.get(k, 0)
    print(f"| {k} | {b} | {a} | {a - b:+d} |")
tb, ta = sum(before.values()), sum(after.values())
print(f"| **total** | {tb} | {ta} | {ta - tb:+d} |")
