module RouteFixturesTest exposing (suite)

import Expect
import Replay
import RouteFixtures
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "the route fixtures, replayed through Rpc.request over Transcode"
        (List.map replay RouteFixtures.fixtures)


replay : Replay.Fixture -> Test
replay fixture =
    test fixture.name <|
        \_ ->
            case fixture.actual of
                Err problem ->
                    Expect.fail problem

                Ok request ->
                    { method = request.method
                    , url = request.url
                    , headers = request.headers
                    , body = Maybe.map Replay.normalize request.body
                    }
                        |> Expect.equal
                            { method = fixture.expected.method
                            , url = fixture.expected.url
                            , headers = fixture.expected.headers
                            , body = Maybe.map Replay.normalize fixture.expected.body
                            }
