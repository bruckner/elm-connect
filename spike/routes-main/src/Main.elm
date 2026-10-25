port module Main exposing (main)

{-| Every call of tests/Routes's service through `Rpc.request` over
Transcode, each binding of each method, so dead-code elimination keeps all
of them. `flags` is how many rounds to build; the port answers with the URLs
of the last round, for the benchmark (bench.js) and for size measurements.
-}

import Routes.V1 as R
import Routes.V1.Routes as S
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Transport
import Time


port done : List String -> Cmd msg


config : Rpc.Config
config =
    let
        base =
            Rpc.config "https://api.example.com"
    in
    { base | transport = Rpc.Transport.transcode }


getMessage : String -> R.GetMessageRequest
getMessage id =
    { messageId = id, revision = "3", sub = Just { subfield = "s" }, userId = "u", name = "messages/" ++ id }


everything : String -> R.Everything
everything id =
    let
        d =
            R.defaultEverything
    in
    { d
        | name = "things/" ++ id
        , count = 7
        , big = "9007199254740993"
        , flag = True
        , ratio = 1.5
        , kind = R.KindText
        , tags = [ "x", "y" ]
        , kinds = [ R.KindImage ]
        , numbers = [ 1, 2 ]
        , maybeCount = Just 0
        , at = Just (Time.millisToPosix 1700000000000)
        , mask = Just [ "a.b", "fooBar" ]
        , limit = Just 3
        , inner = Just { a = "i", deep = Just { b = 4, c = [ "c1" ] } }
        , choice = R.EverythingChoiceText "t"
    }


resource : String -> R.Resource
resource id =
    { name = id, displayName = "D", labels = R.defaultResource.labels, kinds = R.defaultResource.kinds, weights = [] }


{-| One request per binding of every method, `id` threaded into a path
value so that no round shares work with another.
-}
requests : String -> List Rpc.Request
requests id =
    List.concat
        [ List.filterMap (\i -> Rpc.Call.viaBinding i (S.getMessage (getMessage id)) |> Maybe.map (Rpc.request config)) [ 0, 1, 2, 3 ]
        , [ Rpc.request config (S.updateMessage { messageId = id, message = Just { messageId = id, text = "hi" } })
          , Rpc.request config (S.updateMessageWhole { messageId = id, text = "hi" })
          , Rpc.request config (S.postSub (getMessage id))
          , Rpc.request config (S.query (everything id))
          , Rpc.request config (S.single (everything id))
          , Rpc.request config (S.multi (everything id))
          , Rpc.request config (S.typed (everything id))
          , Rpc.request config (S.files { path = "files/" ++ id ++ "/b.txt" })
          , Rpc.request config (S.cancel (resource ("operations/" ++ id)))
          , Rpc.request config (S.updateResource { resource = Just (resource ("resources/" ++ id)), updateMask = Just [ "displayName" ] })
          , Rpc.request config (S.head { path = "files/" ++ id })
          , Rpc.request config (S.unbound (getMessage id))
          ]
        ]


line : Rpc.Request -> String
line r =
    r.method ++ " " ++ r.url ++ " " ++ Maybe.withDefault "" (Rpc.Body.toText r.body)


{-| `n` rounds of `requests`, keeping the last round's lines.
-}
rounds : Int -> List String
rounds n =
    let
        go k acc =
            if k <= 0 then
                acc

            else
                go (k - 1) (List.map line (requests ("m" ++ String.fromInt k)))
    in
    go n []


main : Program Int () ()
main =
    Platform.worker
        { init = \n -> ( (), done (rounds n) )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
