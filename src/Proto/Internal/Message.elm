module Proto.Internal.Message exposing (Codecs(..), Message(..))

{-| The `Message` type, which `Proto.Message` names by an alias. It is defined
here so that other modules of the package can reach what a message type holds
while users cannot.

A message type is its full name and the codecs of one world, which the
`codec` phantom names: `Proto.Message.initJson` gives one in `Json` holding
`JsonCodecs`, `Proto.Message.initProto` one in `Proto` holding `ProtoCodecs`.
The builders are the only way in, so a function on a `Message Proto a` never
meets `JsonCodecs`, and the reverse.

-}

import Bytes.Encode
import Json.Decode
import Json.Encode
import Proto.Internal.Binary


type Message codec a
    = Message String (Codecs a)


type Codecs a
    = JsonCodecs (a -> Json.Encode.Value) (Json.Decode.Decoder a)
    | ProtoCodecs (a -> Bytes.Encode.Encoder) (Proto.Internal.Binary.Decoder a)
