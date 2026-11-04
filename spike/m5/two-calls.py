"""M5's hand edit, done by script: the JSON-wired service module with, after
its calls, the proto-wired calls of the same service (generated under
codec=proto), each renamed with `Proto` at the end (`getNoteProto`).

    python3 spike/m5/two-calls.py JSON_SERVICE.elm PROTO_SERVICE.elm OUT.elm
"""
import re, sys

json_src, proto_src, out = (open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3])


def calls(src):
    """The CALLS section's declarations, each with its doc comment."""
    body = src[src.index('-- CALLS\n'):]
    end = re.search(r'\n-- (ROUTES|DESCRIPTORS)\n', body)
    return body[len('-- CALLS\n'):end.start()]


proto_calls = calls(proto_src)
names = re.findall(r'^([a-z][A-Za-z0-9]*) :', proto_calls, re.M)
for name in names:
    proto_calls = re.sub(rf'^{name} (:|=)', rf'{name}Proto \1', proto_calls, flags=re.M)
imports = set(re.findall(r'^import .*$', json_src, re.M)) | set(re.findall(r'^import .*$', proto_src, re.M))
head_end = json_src.index('\n\n\n', json_src.index('\nimport '))
first_import = json_src.index('\nimport ')
src = json_src[:first_import] + '\n' + '\n'.join(sorted(imports)) + json_src[head_end:]
marker = re.search(r'\n-- (ROUTES|DESCRIPTORS)\n', src)
src = src[:marker.start()] + '\n' + proto_calls.rstrip('\n') + '\n\n\n' + src[marker.start():]
open(out, 'w').write(src)
print(f'{len(names)} proto calls added: {", ".join(n + "Proto" for n in names)}')
