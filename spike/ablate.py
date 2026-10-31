"""Measurement 0's ablation: rewrite a generated `codec=both` package module
with one section's values replaced by stubs of the same name and type, so
the program still compiles against it and only that section's inference and
code generation leave the build.

    python3 spike/ablate.py SECTION IN.elm OUT.elm

SECTION:
  a  merge*Bytes        -> Proto.Binary.merge (\\_ w v -> Proto.Binary.skip w v) identity
  b  binaryRegistry     -> Proto.Registry.empty
  c  message JSON codecs: encodeMsgN -> \\_ -> Json.Encode.null,
                          decodeMsgN -> Json.Decode.succeed defaultMsgN
  d  encode*Bytes       -> \\_ -> Bytes.Encode.sequence []
  e  message* typed values without their binary half (no |> withBinary)

Messages are recognised by their `type alias X =` declarations; enums keep
their codecs (ten of them, the same in every variant).
"""
import re, sys

section, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(src).read().split('\n')
messages = set(re.findall(r'^type alias (\w+) =', '\n'.join(lines), re.M))


def stub(name, params):
    """The replacement body for top-level value `name`, or None to keep it."""
    if section == 'a':
        m = re.fullmatch(r'merge(\w+)Bytes', name)
        if m and m.group(1) in messages:
            return f'{name} =\n    Proto.Binary.merge (\\_ w v -> Proto.Binary.skip w v) identity'
    if section == 'b' and name == 'binaryRegistry':
        return f'{name} =\n    Proto.Registry.empty'
    if section == 'c':
        m = re.fullmatch(r'(encode|decode)(\w+)', name)
        if m and m.group(2) in messages:
            if m.group(1) == 'encode':
                return f'{name} _ =\n    Json.Encode.null'
            return f'{name} =\n    Json.Decode.succeed default{m.group(2)}'
    if section == 'd':
        m = re.fullmatch(r'encode(\w+)Bytes', name)
        if m and m.group(1) in messages:
            return f'{name} _ =\n    Bytes.Encode.sequence []'
    return None


out, i, replaced = [], 0, 0
while i < len(lines):
    line = lines[i]
    m = re.match(r'^([a-z]\w*)((?: \w+)*) =$', line)
    if not m:
        out.append(line)
        i += 1
        continue
    j = i + 1
    while j < len(lines) and (lines[j] == '' or lines[j].startswith(' ')):
        j += 1
    # keep the blank lines before the next declaration
    k = j
    while k > i + 1 and lines[k - 1] == '':
        k -= 1
    body = lines[i:k]
    s = stub(m.group(1), m.group(2))
    if section == 'e' and m.group(1).startswith('message') and m.group(1)[7:] in messages:
        s = '\n'.join(l for l in body if 'Proto.Message.withBinary' not in l)
    if s is not None:
        replaced += 1
        out.extend(s.split('\n'))
    else:
        out.extend(body)
    out.extend(lines[k:j])
    i = j
open(dst, 'w').write('\n'.join(out))
print(f'{section}: {replaced} values replaced', file=sys.stderr)
