"""Why a definition survives dead-code elimination: the shortest chain of
references from the program's entry (`main`, the exported init) to it, in an
`elm make --optimize` output.

    python3 why.py elm.js NAME-SUBSTRING [MAX]

Prints, for each definition whose name contains NAME-SUBSTRING (up to MAX of
them), one chain `main -> ... -> definition`. A chain is one reason; a
definition reached several ways shows only the shortest.
"""
import re, sys, collections
sys.path.insert(0, __import__('os').path.dirname(__file__))
src = open(sys.argv[1]).read()
needle = sys.argv[2]
cap = int(sys.argv[3]) if len(sys.argv) > 3 else 5
head_end = src.index("'use strict';") + len("'use strict';")
tail_start = src.rindex('\n_Platform_export(')
stmts = re.split(r'\n(?=(?:var|function) )', src[head_end:tail_start])
ident = re.compile(r'[A-Za-z_$][A-Za-z0-9_$]*')
defs = {}
for s in stmts:
    m = re.match(r'\s*(?:var|function)\s+([A-Za-z0-9_$]+)', s)
    if m:
        defs[m.group(1)] = s
refs = {n: set(t for t in ident.findall(body) if t in defs and t != n) for n, body in defs.items()}
roots = set(t for t in ident.findall(src[tail_start:]) if t in defs)
prev = {r: None for r in roots}
queue = collections.deque(roots)
while queue:
    n = queue.popleft()
    for m in refs[n]:
        if m not in prev:
            prev[m] = n
            queue.append(m)
short = lambda n: n.replace('$author$project$', '').replace('$elm$', '')
shown = 0
for n in defs:
    if needle in n and n in prev:
        chain = []
        x = n
        while x is not None:
            chain.append(short(x))
            x = prev[x]
        print(' -> '.join(reversed(chain)))
        shown += 1
        if shown >= cap:
            break
