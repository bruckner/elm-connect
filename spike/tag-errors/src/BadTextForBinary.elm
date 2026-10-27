module BadTextForBinary exposing (read)

{-| `Rpc.response`, the text reader, for a client speaking protobuf binary.
-}

import Connectrpc.Eliza.V1 exposing (SayResponse)
import Good
import Http
import Rpc


read : Http.Response String -> Result Rpc.Error SayResponse
read =
    Rpc.response Good.binaryClient (Good.sayBoth { sentence = "hi" })
