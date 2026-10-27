"""Decision 2's alternative representation: a method holds both codec halves
always, a filler standing in for the one its generated code lacks, so
`Rpc.Internal.Send` has no branch for a missing half and a plan no
`problem`. The binary half holds the request's encoder, which the binary
protocols' functions encode, so that the filler (`Bytes.Encode.unsignedInt8
0`, a constructor) reaches no elm/bytes code: `Bytes.Encode.sequence []`
would measure widths, which brings in elm/bytes' whole kernel (+590 B gz on
min, measured). Applied to a copy of the runtime by spike/variant.sh."""
import sys, re
root = sys.argv[1]

def edit(path, pairs):
    p = f'{root}/{path}'
    s = open(p).read()
    for old, new in pairs:
        if old not in s:
            raise SystemExit(f'{path}: not found: {old[:70]!r}')
        s = s.replace(old, new)
    open(p, 'w').write(s)

edit('src/Proto/Internal/Method.elm', [
    ('        , json : Maybe (JsonHalf req res)\n        , binary : Maybe (BinaryHalf req res)',
     '        , json : JsonHalf req res\n        , binary : BinaryHalf req res'),
    ('import Bytes exposing (Bytes)\n', 'import Bytes exposing (Bytes)\nimport Bytes.Encode\n'),
    ('    { encode : req -> Bytes\n', '    { encode : req -> Bytes.Encode.Encoder\n'),
])
edit('src/Proto/Method.elm', [
    ('''        , json = Just { encode = encode, decoder = decoder }
        , binary = Nothing
        , routes = []''', '''        , json = { encode = encode, decoder = decoder }
        , binary = noBinary
        , routes = []'''),
    ('''        , json = Nothing
        , binary = Just (binaryHalf encode decoder)''', '''        , json = noJson
        , binary = binaryHalf encode decoder'''),
    ('''        , json = Just { encode = encode, decoder = decoder }
        , binary = Just (binaryHalf encodeBinary binaryDecoder)''', '''        , json = { encode = encode, decoder = decoder }
        , binary = binaryHalf encodeBinary binaryDecoder'''),
    ('''binaryHalf : (req''', '''{-| The binary half of a method generated without binary codecs: never read,
since no protocol speaking protobuf binary meets such a method.
-}
noBinary : Internal.BinaryHalf req res
noBinary =
    { encode = \\_ -> Bytes.Encode.unsignedInt8 0, decode = \\_ -> Nothing }


{-| The JSON half of a method generated with binary codecs alone: never read.
-}
noJson : Internal.JsonHalf req res
noJson =
    { encode = \\_ -> Json.Encode.null, decoder = Json.Decode.fail "elm-connect: a method without JSON codecs" }


binaryHalf : (req'''),
    ('    { encode = Proto.Binary.encode encode\n', '    { encode = encode\n'),
    ('''                case m.json of
                    Just half ->
                        List.map (\\(Proto.Internal.Binding.Binding rule) req -> Proto.Internal.Interpret.route rule (half.encode req)) methodBindings

                    Nothing ->
                        []''', '''                List.map (\\(Proto.Internal.Binding.Binding rule) req -> Proto.Internal.Interpret.route rule (m.json.encode req)) methodBindings'''),
])
edit('src/Rpc/Call.elm', [
    ('''        Proto.Internal.Method.Method m ->
            case m.json of
                Just half ->
                    half.encode c.message

                Nothing ->
                    Json.Encode.null''', '''        Proto.Internal.Method.Method m ->
            m.json.encode c.message'''),
])
edit('src/Rpc/Internal/Protocol.elm', [
    ('import Bytes exposing (Bytes)\n', 'import Bytes exposing (Bytes)\nimport Bytes.Encode\n'),
    ('    { build : (Bytes -> String) -> Options -> Settings -> Endpoint -> Bytes -> Request\n', '    { build : (Bytes -> String) -> Options -> Settings -> Endpoint -> Bytes.Encode.Encoder -> Request\n'),
    ('    , tooLarge : Options -> Bytes -> Maybe Reason\n', '    , tooLarge : Options -> Bytes.Encode.Encoder -> Maybe Reason\n'),
])
edit('src/Rpc/Internal/Wire.elm', [
    ('import Bytes exposing (Bytes)\n', 'import Bytes exposing (Bytes)\nimport Bytes.Encode\n'),
    ('connectPostBinary : (Bytes -> String) -> Options -> Settings -> Endpoint -> Bytes -> Request\nconnectPostBinary _ _ settings endpoint binary =\n    connectRequest settings endpoint (Body.bytes binary)',
     'connectPostBinary : (Bytes -> String) -> Options -> Settings -> Endpoint -> Bytes.Encode.Encoder -> Request\nconnectPostBinary _ _ settings endpoint encoder =\n    connectRequest settings endpoint (Body.bytes (Bytes.Encode.encode encoder))'),
    ('connectGetBinary : (Bytes -> String) -> Options -> Settings -> Endpoint -> Bytes -> Request\nconnectGetBinary toBase64 options settings endpoint binary =\n',
     'connectGetBinary : (Bytes -> String) -> Options -> Settings -> Endpoint -> Bytes.Encode.Encoder -> Request\nconnectGetBinary toBase64 options settings endpoint encoder =\n    let\n        binary =\n            Bytes.Encode.encode encoder\n    in\n'),
    ('grpcWeb : (Bytes -> String) -> Options -> Settings -> Endpoint -> Bytes -> Request\ngrpcWeb _ _ settings endpoint binary =\n',
     'grpcWeb : (Bytes -> String) -> Options -> Settings -> Endpoint -> Bytes.Encode.Encoder -> Request\ngrpcWeb _ _ settings endpoint encoder =\n'),
    ('GrpcWeb.frame binary)', 'GrpcWeb.frame (Bytes.Encode.encode encoder))'),
    ('bytesTooLarge : Options -> Bytes -> Maybe Reason\nbytesTooLarge options binary =', 'bytesTooLarge : Options -> Bytes.Encode.Encoder -> Maybe Reason\nbytesTooLarge options encoder ='),
    ('                        Bytes.width binary\n', '                        Bytes.width (Bytes.Encode.encode encoder)\n'),
    ('bytesUnlimited : Options -> Bytes -> Maybe Reason', 'bytesUnlimited : Options -> a -> Maybe Reason'),
])
p = f'{root}/src/Rpc/Internal/Send.elm'
s = open(p).read()
for field in ['json', 'binary']:
    pat = re.compile(r'            case m\.' + field + r' of\n                Just half ->\n((?:.*\n)*?)\n                Nothing ->\n                    unplannable "[^"]*"\n')
    m = pat.search(s)
    if not m:
        raise SystemExit('Send: no ' + field + ' case')
    body = re.sub(r'^    ', '', m.group(1), flags=re.M)
    s = s[:m.start()] + '            let\n                half =\n                    m.' + field + '\n            in\n' + body + s[m.end():]
i = s.index('unplannable : String -> Plan res')
j = s.index('{-| Why `sent`', i)
s = s[:i] + s[j:]
s = s.replace('    , problem : Maybe Error\n', '')
s = re.sub(r'\n *, problem = Nothing\n', '\n', s)
s = s.replace('  - `problem`: the internal error of a pairing the types rule out.\n', '')
s = s.replace('''        case ( p.problem, p.invalid, Internal.invalidHeader sent.headers ) of
            ( Just problem, _, _ ) ->
                Just problem

            ( Nothing, Just path, _ ) ->
                Just (Error.NoAnswer (Error.InvalidPathValue path))

            ( Nothing, Nothing, Just name ) ->
                Just (Error.NoAnswer (Error.InvalidHeader name))

            ( Nothing, Nothing, Nothing ) ->''', '''        case ( p.invalid, Internal.invalidHeader sent.headers ) of
            ( Just path, _ ) ->
                Just (Error.NoAnswer (Error.InvalidPathValue path))

            ( Nothing, Just name ) ->
                Just (Error.NoAnswer (Error.InvalidHeader name))

            ( Nothing, Nothing ) ->''')
s = s.replace('import Rpc.Body\n', '')
open(p, 'w').write(s)
