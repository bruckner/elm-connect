"""B without the bytes kind of wire: no binary protocol, no bytes reader, no
`responseBytes`. Not a design: the floor a JSON program would have if the
runtime knew no binary protocol, to measure what the two-way choice on the
wire kind costs a program that never names a binary protocol."""
import sys, re
root = sys.argv[1]

def edit(path, fn):
    p = f'{root}/{path}'
    s = open(p).read()
    t = fn(s)
    if t == s:
        raise SystemExit(f'{path}: unchanged')
    open(p, 'w').write(t)

def arm(s, start, end):
    """Cut from the first occurrence of `start` up to (not including) `end`."""
    i = s.index(start)
    j = s.index(end, i)
    return s[:i] + s[j:]

edit('src/Rpc/Internal/Protocol.elm', lambda s: s.replace('    = Text TextWire\n    | Binary BinaryWire\n', '    = Text TextWire\n'))

def send(s):
    s = arm(s, '        Binary wire ->\n', 'unplannable : String -> Plan res')
    s = s.replace('    = TextReader (Http.Response String -> Result Error res)\n    | BytesReader (Http.Response Bytes -> ( Maybe Http.Metadata, Result Error res ))\n',
                  '    = TextReader (Http.Response String -> Result Error res)\n')
    s = s.replace('                    unplannable "a protocol speaking JSON met a method without JSON codecs"\n',
                  '                    unplannable "a protocol speaking JSON met a method without JSON codecs"\n\n\n')
    return s
edit('src/Rpc/Internal/Send.elm', send)

def protocol(s):
    s = s.replace('    , connect, connectProto, transcode, grpcWeb\n', '    , connect, transcode\n')
    s = s.replace('@docs connect, connectProto, transcode, grpcWeb', '@docs connect, transcode')
    for name in ['connectProto', 'grpcWeb']:
        s = arm(s, '{-|', name + ' : Protocol Proto') if False else s
        i = s.index(name + ' : Protocol Proto')
        doc = s.rindex('{-|', 0, i)
        j = s.index('\n\n\n', i)
        s = s[:doc] + s[j + 3:]
    s = re.sub(r'\n\n *Binary wire ->\n *Binary \{ wire \| \w+ = [\w.]+ \}\n', '\n', s)
    return s
edit('src/Rpc/Protocol.elm', protocol)

def rpc(s):
    s = s.replace(', request, response, responseBytes, taskFromRequest, splitTrailers\n', ', request, response, taskFromRequest, splitTrailers\n')
    s = s.replace('@docs Request, request, response, responseBytes, taskFromRequest, splitTrailers', '@docs Request, request, response, taskFromRequest, splitTrailers')
    i = s.index('responseBytes : Client Proto')
    doc = s.rindex('{-|', 0, i)
    j = s.index('\n\n\n', i)
    s = s[:doc] + s[j + 3:]
    s = re.sub(r'\n\n *BytesReader read ->\n *Http\.expectBytesResponse toMsg \(read >> Tuple\.second\)\n', '\n', s)
    s = re.sub(r'\n\n *BytesReader _ ->\n *Err \(Rpc\.Internal\.Answer\.unreachable "[^"]*"\)', '', s)
    s = re.sub(r'\n\n *BytesReader read ->\n *Http\.bytesResolver \(read >> Ok\)\n', '\n', s)
    return s
edit('src/Rpc.elm', rpc)
