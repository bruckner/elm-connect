module RoutePropertiesTest exposing (suite)

{-| Requests sampled at random from `conformance/routes/routes.proto`, with
the HTTP request the Rust reference makes of each
(`Generated.Routes.Properties`, written by
`crates/elm-connect-gen/tests/routes.rs` at test time), replayed through
`Rpc.request` over Transcode as the route fixtures are. Each request's JSON
is decoded with the generated decoder and re-encoded into the path, query and
body, so this checks the generated codecs against prost-reflect's proto3 JSON
too.
-}

import Generated.Routes.Properties as RouteProperties
import Replay
import Test exposing (Test, describe)


suite : Test
suite =
    describe "the route properties, replayed through Rpc.request over Transcode"
        (List.map Replay.replay RouteProperties.fixtures)
