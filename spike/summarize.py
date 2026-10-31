"""Median and spread of spike/make.sh's lines, by variant:

    python3 spike/summarize.py spike/results/FILE.txt ...

prints `| variant | runs | wall median (min–max) | peak RSS median (min–max) | js |`.
"""
import re, sys
from collections import OrderedDict

rows = OrderedDict()
for path in sys.argv[1:]:
    for line in open(path):
        m = re.match(r'rep\d+ (\S+): status (\d+), ([\d.]+) s, peak RSS (\d+) MB, js (\d+) bytes', line)
        if m:
            rows.setdefault(m.group(1), []).append((float(m.group(3)), int(m.group(4)), int(m.group(5)), m.group(2)))
med = lambda xs: sorted(xs)[len(xs) // 2]
print('| variant | runs | wall s, median (min–max) | peak RSS MB, median (min–max) | optimized JS B |')
print('|---|---:|---:|---:|---:|')
for k, v in rows.items():
    t = [x[0] for x in v]; r = [x[1] for x in v]
    bad = [x[3] for x in v if x[3] != '0']
    print(f'| {k} | {len(v)}{" (failed: " + ",".join(bad) + ")" if bad else ""} | {med(t):.2f} ({min(t):.2f}–{max(t):.2f}) | {med(r):,} ({min(r):,}–{max(r):,}) | {v[0][2]:,} |')
