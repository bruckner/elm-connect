#!/usr/bin/env bash
# Run bench-perf.js on two builds three times (each run alternates them),
# then give each task's min and median over the runs, per build:
#
#   spike/bench3.sh OLD.js NEW.js REGEX OUTDIR
set -euo pipefail
old="$1"; new="$2"; only="$3"; out="$4"
mkdir -p "$out"
for i in 1 2 3; do
    node spike/bench-perf.js "$old" "$new" --only "$only" > "$out/run$i.txt"
done
python3 - "$out" <<'PY'
import sys, re, statistics
out = sys.argv[1]
rows = {}
for i in (1, 2, 3):
    for line in open(f'{out}/run{i}.txt'):
        m = re.match(r'(\S+)\s+([\d.]+)\s+([\d.]+)\s+(-?\d+)%\s+(\d+)(.*)', line)
        if m:
            rows.setdefault(m.group(1), []).append((float(m.group(2)), float(m.group(3)), m.group(6).strip()))
print(f"{'task':28} {'old min':>8} {'old med':>8} {'new min':>8} {'new med':>8} {'med chg':>8}")
for task, runs in rows.items():
    olds = [r[0] for r in runs]; news = [r[1] for r in runs]
    om, nm = statistics.median(olds), statistics.median(news)
    flag = ' CHECKSUM' if any(r[2] for r in runs) else ''
    print(f"{task:28} {min(olds):8.3f} {om:8.3f} {min(news):8.3f} {nm:8.3f} {100 * (nm - om) / om:+7.0f}%{flag}")
PY
