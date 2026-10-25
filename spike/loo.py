"""What leaving some definitions out would save, minified and gzipped: the
cost of a dead-code-elimination blocker before fixing it.

    python3 loo.py elm.js 'LABEL=name1,name2,...' ['LABEL2=...' ...]

Names are compiled names without `$author$project$` (`Rpc$Error$message`);
a name ending in `$` takes every definition with that prefix. Each group is
stubbed as attr2.py stubs a module (`var x = 0;`, every definition kept
alive by an appended array) and the difference from the whole program is
printed, with the group's optimized bytes.
"""
import sys, importlib.util, os
spec = importlib.util.spec_from_file_location('attr2', os.path.join(os.path.dirname(__file__), 'attr2.py'))
src_attr2 = open(spec.origin).read().replace('\nmain()\n', '\n')
attr2 = {}
exec(compile(src_attr2, spec.origin, 'exec'), attr2)
split, name_of, minify = attr2['split'], attr2['name_of'], attr2['minify']

path = sys.argv[1]
src = open(path).read()
head, stmts, tail = split(src)
names = [name_of(s) for s in stmts]
keep = '\nscope.__keep = [' + ','.join(n for n in names if n) + '];'
whole_min, whole_gz = minify(head + '\n'.join(stmts) + keep + tail)
print(f"{'group':28} {'optimized':>9} {'min':>6} {'gz':>5}")
for arg in sys.argv[2:]:
    label, _, spec_names = arg.partition('=')
    wanted = []
    for w in spec_names.split(','):
        full = '$author$project$' + w if not w.startswith('$') else w
        wanted.append(full)
    def hit(n):
        return n and any((n.startswith(w) if w.endswith('$') else n == w) for w in wanted)
    opt = sum(len(s) + 1 for n, s in zip(names, stmts) if hit(n))
    stub = [(f"var {n} = 0;" if hit(n) else s) for n, s in zip(names, stmts)]
    m, g = minify(head + '\n'.join(stub) + keep + tail)
    print(f"{label:28} {opt:9} {whole_min - m:6} {whole_gz - g:5}")
