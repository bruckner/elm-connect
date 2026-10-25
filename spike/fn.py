"""Bytes of an unminified `elm make --optimize` output per definition
under a prefix, grouped by the first DEPTH name segments after it:

    python3 fn.py elm.js '$author$project$Routes$V1$Routes$' 1 40

Copied from the review's attribution scripts."""
import re,sys,collections
src=open(sys.argv[1]).read(); prefix=sys.argv[2]; depth=int(sys.argv[3]); top=int(sys.argv[4])
parts=re.split(r'\nvar (\$[A-Za-z0-9_$]+)\s*=', src)
c=collections.Counter()
for i in range(1,len(parts),2):
    name=parts[i]; n=len(name)+len(parts[i+1])+6
    if name.startswith(prefix):
        seg=name[len(prefix):].split('$')
        c['.'.join(seg[:depth])]+=n
print(prefix, "total", sum(c.values()))
for k,v in c.most_common(top): print(f"  {k:48} {v:7}")
