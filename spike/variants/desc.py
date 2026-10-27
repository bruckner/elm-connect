"""H10's comparison build: each generated method holds its full descriptor
(type names and bindings included, as 0.1's `Rpc.Call.descriptor` read)
rather than its endpoint. The runtime still reads only the endpoint, so
the method is built from `Proto.Method.toEndpoint descriptorX`: what this
measures is the bytes of the descriptor data a program then keeps.
Applied to a copy by spike/variant.sh."""
import sys, re, glob
root = sys.argv[1]
for p in glob.glob(f'{root}/examples/**/generated/**/*Service.elm', recursive=True):
    s = open(p).read()
    t = re.sub(r'(\n\s+)endpoint(\w+)\n(\s+\|>|\s+\))', r'\1(Proto.Method.toEndpoint descriptor\2)\n\3', s)
    if t != s:
        open(p, 'w').write(t)
        print('patched', p)
