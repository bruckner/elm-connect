module Proto.MethodTest exposing (suite)

import Expect
import Proto.Method as Method exposing (Idempotency(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Proto.Method"
        [ test "a method reads back what built it" <|
            \_ ->
                let
                    get =
                        Method.descriptor "t.v1.Events" "Get" IdempotencyIdempotent "t.v1.GetRequest" "t.v1.Event" []
                in
                ( ( Method.service get, Method.name get, Method.idempotency get )
                , ( Method.input get, Method.output get, List.length (Method.bindings get) )
                )
                    |> Expect.equal ( ( "t.v1.Events", "Get", IdempotencyIdempotent ), ( "t.v1.GetRequest", "t.v1.Event", 0 ) )
        ]
