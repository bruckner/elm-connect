module RouteFixturesTest exposing (suite)

import Generated.Routes.Fixtures as RouteFixtures
import Replay
import Test exposing (Test, describe)


suite : Test
suite =
    describe "the route fixtures, replayed through Rpc.request over Transcode"
        (List.map Replay.replay RouteFixtures.fixtures)
