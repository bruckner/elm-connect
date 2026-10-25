module Proto.BinaryUnpackedTest exposing (suite)

import Expect
import Proto.Binary
import Proto.Bytes
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Proto.Binary.listUnpacked"
        [ test "writes one field key per element, where list packs them" <|
            \_ ->
                ( Proto.Bytes.toBase64 (Proto.Binary.encode (Proto.Binary.listUnpacked Proto.Binary.int32 1) [ 1, 2 ])
                , Proto.Bytes.toBase64 (Proto.Binary.encode (Proto.Binary.list Proto.Binary.int32 1) [ 1, 2 ])
                , Proto.Bytes.toBase64 (Proto.Binary.encode (Proto.Binary.listUnpacked Proto.Binary.int32 1) [])
                )
                    -- 08 01 08 02, 0a 02 01 02, nothing
                    |> Expect.equal ( "CAEIAg==", "CgIBAg==", "" )
        ]
