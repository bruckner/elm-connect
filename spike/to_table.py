"""Rewrite a generated module's `merge*Bytes` values (today's
`Proto.Binary.merge (\\number wire value -> case number of ...) finish`)
into another form, keeping every arm's expression (the same helpers and
setters, a oneof message member's "member read before" `case` included) and
the finishing function as they are:

    python3 spike/to_table.py FORM IN.elm OUT.elm

FORM:
  table     Proto.Binary.mergeTable [ ( 1, \\wire value -> <arm> ), ... ] finish
  flatcase  the same `case`, each arm's expression written on one line
            (the formatting change alone, to separate it from the structure)

An arm whose expression holds a `case` is kept on several lines in either
form (elm-format always breaks a `case`). Run elm-format on OUT afterwards.
"""
import re, sys

form, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(src).read().split('\n')


def flat(body):
    """An arm's expression on one line, or None when it holds a `case`."""
    if any(re.search(r'\bcase\b.*\bof$', l) for l in body):
        return None
    text = ' '.join(l.strip() for l in body)
    return re.sub(r'\( ', '(', re.sub(r' \)', ')', text))


def rewrite(block):
    """The merge value's lines (definition line onward) in the new form."""
    head, rest = block[0], block[1:]
    assert rest[0] == '    Proto.Binary.merge', rest[0]
    assert rest[1] == '        (\\number wire value ->', rest[1]
    assert rest[2] == '            case number of', rest[2]
    close = rest.index('        )')
    arms, i = [], 3
    while i < close:
        m = re.match(r'^ {16}(\d+|_) ->$', rest[i])
        if not m:
            i += 1
            continue
        j = i + 1
        while j < close and not re.match(r'^ {16}(\d+|_) ->$', rest[j]):
            j += 1
        body = [l for l in rest[i + 1:j] if l.strip()]
        arms.append((m.group(1), body))
        i = j
    finish = rest[close + 1:]
    out = [head]
    if form == 'flatcase':
        out += rest[:3]
        for number, body in arms:
            out.append(f'                {number} ->')
            one = flat(body)
            out += [f'                    {one}'] if one else body
            out.append('')
        out.pop()
        out.append('        )')
        return out + finish
    out.append('    Proto.Binary.mergeTable')
    first = True
    for number, body in arms:
        if number == '_':
            continue
        lead = '        [ ' if first else '        , '
        first = False
        one = flat(body)
        if one:
            out.append(f'{lead}( {number}, \\wire value -> {one} )')
        else:
            base = min(len(l) - len(l.lstrip()) for l in body)
            out.append(f'{lead}( {number}')
            out.append('          , \\wire value ->')
            out += ['                ' + l[base:] for l in body]
            out.append('          )')
    out.append('        ]' if not first else '        []')
    return out + finish


out, i, count = [], 0, 0
while i < len(lines):
    if re.match(r'^merge\w+Bytes =$', lines[i]):
        j = i + 1
        while j < len(lines) and (lines[j] == '' or lines[j].startswith(' ')):
            j += 1
        k = j
        while lines[k - 1] == '':
            k -= 1
        out += rewrite(lines[i:k]) + lines[k:j]
        count += 1
        i = j
    else:
        out.append(lines[i])
        i += 1
open(dst, 'w').write('\n'.join(out))
print(f'{form}: {count} merge values rewritten', file=sys.stderr)
