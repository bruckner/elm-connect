module Proto.MethodTest exposing (suite)

import Expect
import Proto.Method as Method exposing (Idempotency(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Proto.Method"
        [ test "a descriptor reads back what built it" <|
            \_ ->
                let
                    get =
                        Method.descriptor (Method.endpoint "t.v1.Events" "Get" IdempotencyIdempotent) "t.v1.GetRequest" "t.v1.Event" []

                    endpoint =
                        Method.toEndpoint get
                in
                ( ( Method.service endpoint, Method.name endpoint, Method.idempotency endpoint )
                , ( Method.input get, Method.output get, List.length (Method.bindings get) )
                )
                    |> Expect.equal ( ( "t.v1.Events", "Get", IdempotencyIdempotent ), ( "t.v1.GetRequest", "t.v1.Event", 0 ) )
        , test "endpoints built alike are ==" <|
            \_ ->
                Method.endpoint "t.v1.Events" "Get" IdempotencyIdempotent
                    |> Expect.equal (Method.endpoint "t.v1.Events" "Get" IdempotencyIdempotent)
        ]
