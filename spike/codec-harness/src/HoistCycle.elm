port module HoistCycle exposing (main)

{-| Does a hoisted codec of a recursive message compile and run? `codecNode`
is a top-level value whose decoder refers back to it.
-}

import Bytes.Decode
import Bytes.Encode as E
import Proto.Binary


port done : String -> Cmd msg


type Node
    = Node { label : String, children : List Node }


defaultNode : Node
defaultNode =
    Node { label = "", children = [] }


codecNode : Proto.Binary.Codec Node
codecNode =
    Proto.Binary.embedded encodeNode decodeNode defaultNode


encodeNode : Node -> E.Encoder
encodeNode (Node n) =
    E.sequence [ Proto.Binary.implicit Proto.Binary.string 1 n.label, Proto.Binary.list codecNode 2 n.children ]


decodeNode : Int -> Bytes.Decode.Decoder Node
decodeNode =
    Proto.Binary.message { label = "", children = [] }
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field Proto.Binary.string (\v -> { value | label = v }) wire

                2 ->
                    Proto.Binary.repeated codecNode (\v -> { value | children = v }) value.children wire

                _ ->
                    Proto.Binary.skip wire value
        )
        (\value -> { value | children = List.reverse value.children })
        >> Bytes.Decode.map Node


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    tree =
                        Node { label = "a", children = [ Node { label = "b", children = [ Node { label = "c", children = [] } ] } ] }

                    back =
                        Proto.Binary.decode decodeNode (Proto.Binary.encode encodeNode tree)
                in
                ( (), done (Debug.toString back) )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
