"""Tally a protobuf conformance run by level and format: the cases the testee
runs (a failure list from a TESTEE_FAIL_ALL=1 run names them all) and the
cases it failed (the run's failing_tests.txt).

    python3 tally.py ALL_FAILING.txt OUR_FAILING.txt
"""
import sys, collections

def names(path):
    return [line.split('#')[0].strip() for line in open(path) if line.strip() and not line.startswith('#')]

def kind(name):
    parts = name.split('.')
    inp = 'binary' if ('ProtobufInput' in parts or 'ProtoInput' in name) else 'json' if ('JsonInput' in parts) else '?'
    out = 'binary' if name.endswith('.ProtobufOutput') else 'json' if name.endswith('.JsonOutput') else 'none'
    if inp == '?':
        inp = 'json' if out == 'json' else 'binary'
    if inp == 'binary' and out in ('binary', 'none'):
        return 'binary → binary'
    if inp == 'json' and out in ('json', 'none'):
        return 'JSON → JSON'
    return 'binary → JSON' if inp == 'binary' else 'JSON → binary'

every = names(sys.argv[1])
failed = set(names(sys.argv[2]))
table = collections.defaultdict(lambda: [0, 0])
for n in every:
    key = (n.split('.')[0], kind(n))
    table[key][0] += 1
    if n not in failed:
        table[key][1] += 1
print('| level | formats | cases | passed | failed |')
print('|---|---|---:|---:|---:|')
for key in sorted(table):
    total, ok = table[key]
    print(f'| {key[0]} | {key[1]} | {total} | {ok} | {total - ok} |')
for level in ('Required', 'Recommended'):
    t = sum(v[0] for k, v in table.items() if k[0] == level)
    o = sum(v[1] for k, v in table.items() if k[0] == level)
    print(f'| {level} | all | {t} | {o} | {t - o} |')
missing = failed - set(every)
if missing:
    print('failed but not in the full list:', sorted(missing))
