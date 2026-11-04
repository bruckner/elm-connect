"""Attribute an `elm make --optimize` output to modules, kernel code
included, and estimate each module's minified and gzipped share by leaving
it out.

    python3 attr2.py elm.js GEN1,GEN2 [loo-prefix ...]

Statements are split at every top-level `var`/`function`, so kernel code
(`_Json_*`, `_Http_*`, the `F2`/`A2` helpers) is counted under its package
rather than under whichever definition precedes it, as attr.py does. Keys:
runtime:<Module> (the package's Rpc.*/Proto.*), generated:<Module> (the
prefixes given), app:<Module>, pkg:<author/package> and kernel:<package>.

Leave-one-out: for each key whose name starts with one of the loo prefixes
(`runtime:`, `generated:`, ...), every one of its statements is replaced by
`var <name> = 0;` (so references stay bound and keep their mangled names),
the result is minified with terser (--compress --mangle) and gzipped (-9),
and the key's share is the difference from the whole program. Both the whole
and every variant end with an array naming every top-level definition, so
terser cannot drop code that only a stubbed definition referred to; the
array's bytes cancel out in the difference. Shares do not
add up exactly: compression interacts across modules.
"""
import re, sys, collections, subprocess, gzip, os, tempfile

KERNEL = {
    'Json': 'elm/json', 'Http': 'elm/http', 'Bytes': 'elm/bytes', 'Time': 'elm/time',
    'File': 'elm/file', 'Browser': 'elm/browser', 'VirtualDom': 'elm/virtual-dom',
    'Url': 'elm/url', 'Parser': 'elm/parser',
}

def split(src):
    head_end = src.index("'use strict';") + len("'use strict';")
    # The program's last statement is followed by the export and the IIFE's end.
    tail_start = src.rindex('\n_Platform_export(')
    head, body, tail = src[:head_end], src[head_end:tail_start], src[tail_start:]
    stmts = re.split(r'\n(?=(?:var|function) )', body)
    return head, stmts, tail

def name_of(stmt):
    m = re.match(r'\s*(?:var|function)\s+([A-Za-z0-9_$]+)', stmt)
    return m.group(1) if m else None

def key_of(name, generated):
    if name is None:
        return 'other'
    if name.startswith('$'):
        seg = name.split('$')[1:]
        if seg[0] == 'author':
            mods = seg[2:-1]
            if mods[:1] in (['Rpc'], ['Proto']):
                return 'runtime:' + '.'.join(mods)
            if mods[:1] and mods[0] in generated:
                return 'generated:' + '.'.join(mods)
            return 'app:' + ('.'.join(mods) or '?')
        return 'pkg:' + seg[0] + '/' + seg[1]
    m = re.match(r'_([A-Za-z]+)_', name)
    if m:
        return 'kernel:' + KERNEL.get(m.group(1), 'elm/core')
    return 'kernel:elm/core'  # F2, A2, ...

def minify(js):
    with tempfile.TemporaryDirectory() as d:
        a, b = os.path.join(d, 'a.js'), os.path.join(d, 'b.js')
        open(a, 'w').write(js)
        subprocess.run(['npx', '--yes', 'terser@5.36.0', a, '--compress', '--mangle', '-o', b],
                       check=True, stderr=subprocess.DEVNULL)
        m = open(b, 'rb').read()
    return len(m), len(gzip.compress(m, 9, mtime=0))

def main():
    path = sys.argv[1]
    generated = set(sys.argv[2].split(','))
    loo = sys.argv[3:]
    src = open(path).read()
    head, stmts, tail = split(src)
    keys = [key_of(name_of(s), generated) for s in stmts]
    sizes = collections.Counter()
    for k, s in zip(keys, stmts):
        sizes[k] += len(s) + 1
    names = [n for n in (name_of(s) for s in stmts) if n]
    keep = '\nscope.__keep = [' + ','.join(names) + '];'
    whole_min, whole_gz = minify(head + '\n'.join(stmts) + keep + tail) if loo else (0, 0)
    print(f"optimized {len(src)} (statements {sum(sizes.values())}, frame {len(head) + len(tail)})")
    if loo:
        print(f"with keep array: minified {whole_min}  gzip {whole_gz} (python gzip -9, mtime 0)")
    groups = collections.Counter()
    for k, v in sizes.items():
        groups[k.split(':')[0]] += v
    for g, v in groups.most_common():
        print(f"  group {g:10} {v:9}")
    print(f"{'key':44} {'optimized':>9} {'min share':>9} {'gz share':>8}")
    for k, v in sizes.most_common():
        row = f"  {k:42} {v:9}"
        if any(k.startswith(p) for p in loo):
            stub = [(f"var {name_of(s)} = 0;" if kk == k else s) for kk, s in zip(keys, stmts)]
            m, g = minify(head + '\n'.join(stub) + keep + tail)
            row += f" {whole_min - m:9} {whole_gz - g:8}"
        print(row)

main()
