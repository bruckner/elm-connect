module ErrorDetailsSyncTest exposing (suite)

{-| `Proto.ErrorDetails` against the generator: the module is written by hand
in generated code's form, and this compares it with `Google.Rpc`, generated
from the same `google/rpc/error_details.proto` under `wire=both`
(`just error-details-check`, conformance/README.md).

  - **Shape**, at compile time: `agree` takes both sides' typed values at one
    record type, so a field added, removed, renamed or retyped on either side
    of any message, nested ones included, is a compile error naming it. The
    fixtures are built as the generated types and handed to the hand codecs;
    what the hand decoders give is handed to the generated encoders. The
    proto declares no enum, so there is none to compare.
  - **Coverage**: the two registries hold the same full names, the ones
    compared here, so a message on one side only fails.
  - **Codecs**, at run time: for a fixture that sets every field (nested
    messages, repeated fields, maps, a `Duration`, 64-bit integers) and for
    the default, both sides write the same proto3 JSON and the same binary,
    and each side's decoders read either side's output back to the value.
    Both read an empty object and empty bytes as the generated default.

-}

import Bytes exposing (Bytes)
import Dict
import Expect
import Google.Rpc as Generated
import Json.Decode
import Json.Encode
import Proto.Binary
import Proto.Bytes
import Proto.Duration as Duration
import Proto.ErrorDetails as Hand
import Proto.Internal.Message as Internal
import Proto.Internal.Registry
import Proto.Message exposing (Message)
import Proto.Registry exposing (Registry)
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Proto.ErrorDetails against the generated Google.Rpc"
        [ test "both registries hold the messages compared here" <|
            \_ ->
                ( names Hand.registry, names Generated.registry )
                    |> Expect.equal ( List.sort compared, List.sort compared )
        , agree Hand.errorInfo Generated.messageErrorInfo Generated.defaultErrorInfo errorInfo
        , agree Hand.retryInfo Generated.messageRetryInfo Generated.defaultRetryInfo retryInfo
        , agree Hand.debugInfo Generated.messageDebugInfo Generated.defaultDebugInfo debugInfo
        , agree Hand.quotaFailure Generated.messageQuotaFailure Generated.defaultQuotaFailure quotaFailure
        , agree Hand.quotaFailureViolation Generated.messageQuotaFailureViolation Generated.defaultQuotaFailureViolation quotaFailureViolation
        , agree Hand.preconditionFailure Generated.messagePreconditionFailure Generated.defaultPreconditionFailure preconditionFailure
        , agree Hand.preconditionFailureViolation Generated.messagePreconditionFailureViolation Generated.defaultPreconditionFailureViolation preconditionFailureViolation
        , agree Hand.badRequest Generated.messageBadRequest Generated.defaultBadRequest badRequest
        , agree Hand.badRequestFieldViolation Generated.messageBadRequestFieldViolation Generated.defaultBadRequestFieldViolation badRequestFieldViolation
        , agree Hand.requestInfo Generated.messageRequestInfo Generated.defaultRequestInfo requestInfo
        , agree Hand.resourceInfo Generated.messageResourceInfo Generated.defaultResourceInfo resourceInfo
        , agree Hand.help Generated.messageHelp Generated.defaultHelp help
        , agree Hand.helpLink Generated.messageHelpLink Generated.defaultHelpLink helpLink
        , agree Hand.localizedMessage Generated.messageLocalizedMessage Generated.defaultLocalizedMessage localizedMessage
        ]


{-| The full names `suite` compares, one per `agree`.
-}
compared : List String
compared =
    [ "google.rpc.ErrorInfo"
    , "google.rpc.RetryInfo"
    , "google.rpc.DebugInfo"
    , "google.rpc.QuotaFailure"
    , "google.rpc.QuotaFailure.Violation"
    , "google.rpc.PreconditionFailure"
    , "google.rpc.PreconditionFailure.Violation"
    , "google.rpc.BadRequest"
    , "google.rpc.BadRequest.FieldViolation"
    , "google.rpc.RequestInfo"
    , "google.rpc.ResourceInfo"
    , "google.rpc.Help"
    , "google.rpc.Help.Link"
    , "google.rpc.LocalizedMessage"
    ]


names : Registry -> List String
names (Proto.Internal.Registry.Registry _ entries) =
    Dict.keys entries



-- COMPARING


{-| The hand and generated typed values of one message, its generated
default and a fixture setting every field: the tests that they agree.
-}
agree : Message a -> Message a -> a -> a -> Test
agree hand generated default fixture =
    let
        name =
            Proto.Message.typeName generated
    in
    describe name
        [ test "the full names match" <|
            \_ -> Proto.Message.typeName hand |> Expect.equal name
        , describe "a fixture setting every field" (codecs hand generated fixture)
        , describe "the default" (codecs hand generated default)
        , test "both read an empty object as the default" <|
            \_ ->
                ( Json.Decode.decodeString (decoder hand) "{}", Json.Decode.decodeString (decoder generated) "{}" )
                    |> Expect.equal ( Ok default, Ok default )
        , test "both read empty bytes as the default" <|
            \_ ->
                ( decodeBytes hand Proto.Bytes.empty, decodeBytes generated Proto.Bytes.empty )
                    |> Expect.equal ( Just default, Just default )
        ]


codecs : Message a -> Message a -> a -> List Test
codecs hand generated value =
    [ test "the proto3 JSON matches" <|
        \_ -> encodeJson hand value |> Expect.equal (encodeJson generated value)
    , test "the binary matches" <|
        \_ -> base64 hand value |> Expect.equal (base64 generated value)
    , test "each side reads either side's proto3 JSON back" <|
        \_ ->
            crossed (\from to -> Json.Decode.decodeString (decoder to) (encodeJson from value) |> Result.toMaybe) hand generated
                |> Expect.equal (List.repeat 4 (Just value))
    , test "each side reads either side's binary back" <|
        \_ ->
            crossed (\from to -> decodeBytes to (Proto.Binary.encode (encoder from) value)) hand generated
                |> Expect.equal (List.repeat 4 (Just value))
    , test "what one side reads, the other writes as it was written" <|
        \_ ->
            [ Maybe.map (base64 generated) (decodeBytes hand (Proto.Binary.encode (encoder generated) value))
            , Maybe.map (base64 hand) (decodeBytes generated (Proto.Binary.encode (encoder hand) value))
            ]
                |> Expect.equal (List.repeat 2 (Just (base64 generated value)))
    ]


{-| A conversion from each side to each side: hand to hand, hand to
generated, generated to hand, generated to generated.
-}
crossed : (Message a -> Message a -> b) -> Message a -> Message a -> List b
crossed convert hand generated =
    [ convert hand hand, convert hand generated, convert generated hand, convert generated generated ]


encodeJson : Message a -> a -> String
encodeJson (Internal.Message _ c) value =
    c.encodeJson Proto.Registry.empty value
        |> Result.map (Json.Encode.encode 0)
        |> Result.withDefault "unwritable"


decoder : Message a -> Json.Decode.Decoder a
decoder (Internal.Message _ c) =
    c.decodeJson Proto.Registry.empty


encoder : Message a -> a -> Proto.Binary.Encoder
encoder (Internal.Message _ c) =
    c.encodeBinary


decodeBytes : Message a -> Bytes -> Maybe a
decodeBytes (Internal.Message _ c) =
    Proto.Binary.decode c.decodeBinary >> Result.toMaybe


{-| The binary as base64, since Elm's `==` does not look inside `Bytes`.
-}
base64 : Message a -> a -> String
base64 message value =
    Proto.Bytes.toBase64 (Proto.Binary.encode (encoder message) value)



-- FIXTURES


errorInfo : Generated.ErrorInfo
errorInfo =
    { reason = "API_DISABLED"
    , domain = "example.com"
    , metadata = Dict.fromList [ ( "resource", "projects/123" ), ( "service", "pubsub.example.com" ) ]
    }


retryInfo : Generated.RetryInfo
retryInfo =
    { retryDelay = Just (Duration.fromParts 3 250000000)
    }


debugInfo : Generated.DebugInfo
debugInfo =
    { stackEntries = [ "main.go:12", "handler.go:40" ]
    , detail = "nil dereference"
    }


quotaFailure : Generated.QuotaFailure
quotaFailure =
    { violations = [ quotaFailureViolation, { quotaFailureViolation | subject = "user:2", futureQuotaValue = Nothing } ]
    }


quotaFailureViolation : Generated.QuotaFailureViolation
quotaFailureViolation =
    { subject = "user:1"
    , description = "Daily limit reached"
    , apiService = "notes.example.com"
    , quotaMetric = "notes.example.com/writes"
    , quotaId = "WritesPerDay"
    , quotaDimensions = Dict.fromList [ ( "region", "eu" ), ( "tier", "free" ) ]
    , quotaValue = "9007199254740993"
    , futureQuotaValue = Just "-12"
    }


preconditionFailure : Generated.PreconditionFailure
preconditionFailure =
    { violations = [ preconditionFailureViolation, { preconditionFailureViolation | type_ = "LICENSE" } ]
    }


preconditionFailureViolation : Generated.PreconditionFailureViolation
preconditionFailureViolation =
    { type_ = "TOS"
    , subject = "example.com"
    , description = "Terms of service not accepted"
    }


badRequest : Generated.BadRequest
badRequest =
    { fieldViolations = [ badRequestFieldViolation, { badRequestFieldViolation | field = "note.body", localizedMessage = Nothing } ]
    }


badRequestFieldViolation : Generated.BadRequestFieldViolation
badRequestFieldViolation =
    { field = "note.title"
    , description = "must not be empty"
    , reason = "EMPTY"
    , localizedMessage = Just localizedMessage
    }


requestInfo : Generated.RequestInfo
requestInfo =
    { requestId = "req-7f3a"
    , servingData = "stack:abc"
    }


resourceInfo : Generated.ResourceInfo
resourceInfo =
    { resourceType = "notes.example.com/Note"
    , resourceName = "notes/1"
    , owner = "user:1"
    , description = "not found"
    }


help : Generated.Help
help =
    { links = [ helpLink, { helpLink | url = "https://example.com/faq" } ]
    }


helpLink : Generated.HelpLink
helpLink =
    { description = "Docs"
    , url = "https://example.com/docs"
    }


localizedMessage : Generated.LocalizedMessage
localizedMessage =
    { locale = "de-CH"
    , message = "Titel darf nicht leer sein — ✓"
    }
