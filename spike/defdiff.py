"""Definitions that differ between two compiled programs: those only in A,
only in B, and those in both whose optimized text differs in length (a
change of equal length is record fields' short names renumbered), with their
optimized bytes in each, so that loo.py can attribute a size difference.

    python3 spike/defdiff.py A.js B.js
"""
import sys, importlib.util, os
spec = importlib.util.spec_from_file_location('attr2', os.path.join(os.path.dirname(__file__), 'attr2.py'))
src_attr2 = open(spec.origin).read().replace('\nmain()\n', '\n')
attr2 = {}
exec(compile(src_attr2, spec.origin, 'exec'), attr2)
split, name_of = attr2['split'], attr2['name_of']


def defs(path):
    _, stmts, _ = split(open(path).read())
    return {name_of(s): s for s in stmts if name_of(s)}


a, b = defs(sys.argv[1]), defs(sys.argv[2])
short = lambda n: n.replace('$author$project$', '')
for title, names in [('only in A', sorted(set(a) - set(b))), ('only in B', sorted(set(b) - set(a))),
                     ('changed in length', sorted(n for n in set(a) & set(b) if len(a[n]) != len(b[n])))]:
    print(f'## {title}: {len(names)}')
    for n in names:
        print(f'  {short(n):60} {len(a.get(n, "")):6} {len(b.get(n, "")):6}')
