"""Bytes and lines of each `merge*Bytes` value (its definition line and
body, not its doc comment or annotation) in elm-formatted modules:

    python3 spike/merge_size.py LABEL=FILE.elm ...

prints, per message, bytes/lines in each file, then the totals and the
merge section's share of the module.
"""
import re, sys

cols, data = [], {}
for arg in sys.argv[1:]:
    label, path = arg.split('=', 1)
    cols.append(label)
    lines = open(path).read().split('\n')
    total = sum(len(l) + 1 for l in lines)
    i = 0
    while i < len(lines):
        m = re.match(r'^merge(\w+)Bytes =$', lines[i])
        if not m:
            i += 1
            continue
        j = i + 1
        while j < len(lines) and (lines[j] == '' or lines[j].startswith(' ')):
            j += 1
        while lines[j - 1] == '':
            j -= 1
        body = lines[i:j]
        data.setdefault(m.group(1), {})[label] = (sum(len(l) + 1 for l in body), len(body))
        i = j
    data.setdefault('(module)', {})[label] = (total, len(lines))

print('| message | ' + ' | '.join(f'{c} bytes / lines' for c in cols) + ' |')
print('|---|' + '---:|' * len(cols))
msgs = [k for k in data if k != '(module)']
show = msgs if len(msgs) <= 20 else msgs[:3] + ['…'] + msgs[-2:]
for k in show:
    if k == '…':
        print('| … |' + ' |' * len(cols))
        continue
    print(f'| {k} | ' + ' | '.join(f'{data[k][c][0]:,} / {data[k][c][1]}' for c in cols) + ' |')
tot = {c: (sum(data[k][c][0] for k in msgs), sum(data[k][c][1] for k in msgs)) for c in cols}
print(f'| all {len(msgs)} merges | ' + ' | '.join(f'{tot[c][0]:,} / {tot[c][1]:,}' for c in cols) + ' |')
per = {c: [data[k][c][0] for k in msgs] for c in cols}
print('| per message, min–max bytes | ' + ' | '.join(f'{min(per[c]):,}–{max(per[c]):,}' for c in cols) + ' |')
print('| module | ' + ' | '.join(f'{data["(module)"][c][0]:,} / {data["(module)"][c][1]:,}' for c in cols) + ' |')
print('| merges / module | ' + ' | '.join(f'{100 * tot[c][0] / data["(module)"][c][0]:.0f} %' for c in cols) + ' |')
