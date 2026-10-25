module ElementTest exposing (suite)

import Connectrpc.Eliza.V1.ElizaService as ElizaService
import Expect
import Json.Encode as Encode
import Rpc
import Rpc.Retry
import Rpc.Stream exposing (Event(..))
import Rpc.Stream.Element
import Rpc.Stream.Session as Session
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query


type Msg
    = Got Session.Msg


options : Session.Options { name : String } { sentence : String }
options =
    { config = Rpc.config "https://demo.connectrpc.com"
    , call = \_ -> ElizaService.introduce { name = "Ada" }
    , retry = Rpc.Retry.on []
    , idleTimeout = Nothing
    , reconnectOnEnd = False
    }


suite : Test
suite =
    describe "connect-stream"
        [ test "an event dispatched by the element reaches the Session as a port event would" <|
            \_ ->
                let
                    ( session, _, _ ) =
                        Session.update options { out = \_ -> Cmd.none, toMsg = Got } Session.start (Session.init "introduce")

                    id =
                        Session.liveId session |> Maybe.withDefault ""

                    frame =
                        Encode.object [ ( "id", Encode.string id ), ( "kind", Encode.string "message" ), ( "json", Encode.string "{\"sentence\":\"Hi Ada.\"}" ) ]

                    html =
                        Rpc.Stream.Element.view { command = Nothing, onEvent = Got << Session.incoming }
                in
                Query.fromHtml html
                    |> Event.simulate (Event.custom "stream" (Encode.object [ ( "detail", frame ) ]))
                    |> Event.toResult
                    |> Result.map
                        (\(Got msg) ->
                            let
                                ( _, _, event ) =
                                    Session.update options { out = \_ -> Cmd.none, toMsg = Got } msg session
                            in
                            event
                        )
                    |> Expect.equal (Ok (Just (Message { sentence = "Hi Ada." })))
        ]
