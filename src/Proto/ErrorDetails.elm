module Proto.ErrorDetails exposing
    ( ErrorInfo, RetryInfo, DebugInfo
    , QuotaFailure, QuotaFailureViolation
    , PreconditionFailure, PreconditionFailureViolation
    , BadRequest, BadRequestFieldViolation
    , RequestInfo, ResourceInfo, Help, HelpLink, LocalizedMessage
    , errorInfo, retryInfo, debugInfo
    , quotaFailure, quotaFailureViolation
    , preconditionFailure, preconditionFailureViolation
    , badRequest, badRequestFieldViolation
    , requestInfo, resourceInfo, help, helpLink, localizedMessage
    , registry
    )

{-| The error details of `google/rpc/error_details.proto`, the messages a
server packs in a status's details, as Elm records in the form generated
code gives them, with their typed values (both codecs) and a registry
holding all of them. A nested message is named as the generator flattens
it: `google.rpc.BadRequest.FieldViolation` is `BadRequestFieldViolation`.

    status.details
        |> List.filterMap Result.toMaybe
        |> List.filterMap (Proto.Any.unpack Proto.ErrorDetails.badRequest)

A Connect or gRPC-Web error carries its details as protobuf binary, which
unpacks with these values and no registry. Over transcoding, a
`google.rpc.Status` body carries them as proto3 JSON, which the client reads
through its registry: give it [`registry`](#registry)
([`Rpc.Client.withRegistry`](Rpc-Client#withRegistry)), or the details read as
[`UnregisteredType`](Proto-Error#Error).

`google.rpc.Status` itself is not here: [`Rpc.Error`](Rpc-Error) reads it.


# Types

@docs ErrorInfo, RetryInfo, DebugInfo
@docs QuotaFailure, QuotaFailureViolation
@docs PreconditionFailure, PreconditionFailureViolation
@docs BadRequest, BadRequestFieldViolation
@docs RequestInfo, ResourceInfo, Help, HelpLink, LocalizedMessage


# Typed values

@docs errorInfo, retryInfo, debugInfo
@docs quotaFailure, quotaFailureViolation
@docs preconditionFailure, preconditionFailureViolation
@docs badRequest, badRequestFieldViolation
@docs requestInfo, resourceInfo, help, helpLink, localizedMessage


# Registry

@docs registry

-}

import Bytes.Encode
import Dict exposing (Dict)
import Json.Decode
import Json.Encode
import Proto.Binary
import Proto.Duration
import Proto.Error
import Proto.Json.Decode
import Proto.Json.Encode
import Proto.Message
import Proto.Registry



-- TYPES


{-| `google.rpc.ErrorInfo`: why the call failed, as a `reason` constant
within a `domain`, with structured `metadata`.
-}
type alias ErrorInfo =
    { reason : String
    , domain : String
    , metadata : Dict String String
    }


{-| `google.rpc.RetryInfo`: how long to wait before retrying the call.
-}
type alias RetryInfo =
    { retryDelay : Maybe Proto.Duration.Duration
    }


{-| `google.rpc.DebugInfo`: the server's stack entries and debugging text.
-}
type alias DebugInfo =
    { stackEntries : List String
    , detail : String
    }


{-| `google.rpc.QuotaFailure`: the quota checks the call failed.
-}
type alias QuotaFailure =
    { violations : List QuotaFailureViolation
    }


{-| `google.rpc.QuotaFailure.Violation`: one quota check the call failed.
-}
type alias QuotaFailureViolation =
    { subject : String
    , description : String
    , apiService : String
    , quotaMetric : String
    , quotaId : String
    , quotaDimensions : Dict String String
    , quotaValue : String
    , futureQuotaValue : Maybe String
    }


{-| `google.rpc.PreconditionFailure`: the preconditions the call failed.
-}
type alias PreconditionFailure =
    { violations : List PreconditionFailureViolation
    }


{-| `google.rpc.PreconditionFailure.Violation`: one precondition the call
failed.
-}
type alias PreconditionFailureViolation =
    { type_ : String
    , subject : String
    , description : String
    }


{-| `google.rpc.BadRequest`: the fields of the request that were not valid.
-}
type alias BadRequest =
    { fieldViolations : List BadRequestFieldViolation
    }


{-| `google.rpc.BadRequest.FieldViolation`: one field of the request that was
not valid, by its path, and why.
-}
type alias BadRequestFieldViolation =
    { field : String
    , description : String
    , reason : String
    , localizedMessage : Maybe LocalizedMessage
    }


{-| `google.rpc.RequestInfo`: the server's identifier for the request, to
quote when reporting it.
-}
type alias RequestInfo =
    { requestId : String
    , servingData : String
    }


{-| `google.rpc.ResourceInfo`: the resource the call reached.
-}
type alias ResourceInfo =
    { resourceType : String
    , resourceName : String
    , owner : String
    , description : String
    }


{-| `google.rpc.Help`: links to documentation or to an action that resolves
the error.
-}
type alias Help =
    { links : List HelpLink
    }


{-| `google.rpc.Help.Link`: one such link.
-}
type alias HelpLink =
    { description : String
    , url : String
    }


{-| `google.rpc.LocalizedMessage`: a message for the user, in a locale.
-}
type alias LocalizedMessage =
    { locale : String
    , message : String
    }



-- TYPED VALUES


{-| The typed value of [`ErrorInfo`](#ErrorInfo), to pack and unpack an `Any` with.
-}
errorInfo : Proto.Message.Message ErrorInfo
errorInfo =
    Proto.Message.init "google.rpc.ErrorInfo" encodeErrorInfo decodeErrorInfo encodeErrorInfoBinary decodeErrorInfoBinary


{-| The typed value of [`RetryInfo`](#RetryInfo), to pack and unpack an `Any` with.
-}
retryInfo : Proto.Message.Message RetryInfo
retryInfo =
    Proto.Message.init "google.rpc.RetryInfo" encodeRetryInfo decodeRetryInfo encodeRetryInfoBinary decodeRetryInfoBinary


{-| The typed value of [`DebugInfo`](#DebugInfo), to pack and unpack an `Any` with.
-}
debugInfo : Proto.Message.Message DebugInfo
debugInfo =
    Proto.Message.init "google.rpc.DebugInfo" encodeDebugInfo decodeDebugInfo encodeDebugInfoBinary decodeDebugInfoBinary


{-| The typed value of [`QuotaFailure`](#QuotaFailure), to pack and unpack an `Any` with.
-}
quotaFailure : Proto.Message.Message QuotaFailure
quotaFailure =
    Proto.Message.init "google.rpc.QuotaFailure" encodeQuotaFailure decodeQuotaFailure encodeQuotaFailureBinary decodeQuotaFailureBinary


{-| The typed value of [`QuotaFailureViolation`](#QuotaFailureViolation), to pack and unpack an `Any` with.
-}
quotaFailureViolation : Proto.Message.Message QuotaFailureViolation
quotaFailureViolation =
    Proto.Message.init "google.rpc.QuotaFailure.Violation" encodeQuotaFailureViolation decodeQuotaFailureViolation encodeQuotaFailureViolationBinary decodeQuotaFailureViolationBinary


{-| The typed value of [`PreconditionFailure`](#PreconditionFailure), to pack and unpack an `Any` with.
-}
preconditionFailure : Proto.Message.Message PreconditionFailure
preconditionFailure =
    Proto.Message.init "google.rpc.PreconditionFailure" encodePreconditionFailure decodePreconditionFailure encodePreconditionFailureBinary decodePreconditionFailureBinary


{-| The typed value of [`PreconditionFailureViolation`](#PreconditionFailureViolation), to pack and unpack an `Any` with.
-}
preconditionFailureViolation : Proto.Message.Message PreconditionFailureViolation
preconditionFailureViolation =
    Proto.Message.init "google.rpc.PreconditionFailure.Violation" encodePreconditionFailureViolation decodePreconditionFailureViolation encodePreconditionFailureViolationBinary decodePreconditionFailureViolationBinary


{-| The typed value of [`BadRequest`](#BadRequest), to pack and unpack an `Any` with.
-}
badRequest : Proto.Message.Message BadRequest
badRequest =
    Proto.Message.init "google.rpc.BadRequest" encodeBadRequest decodeBadRequest encodeBadRequestBinary decodeBadRequestBinary


{-| The typed value of [`BadRequestFieldViolation`](#BadRequestFieldViolation), to pack and unpack an `Any` with.
-}
badRequestFieldViolation : Proto.Message.Message BadRequestFieldViolation
badRequestFieldViolation =
    Proto.Message.init "google.rpc.BadRequest.FieldViolation" encodeBadRequestFieldViolation decodeBadRequestFieldViolation encodeBadRequestFieldViolationBinary decodeBadRequestFieldViolationBinary


{-| The typed value of [`RequestInfo`](#RequestInfo), to pack and unpack an `Any` with.
-}
requestInfo : Proto.Message.Message RequestInfo
requestInfo =
    Proto.Message.init "google.rpc.RequestInfo" encodeRequestInfo decodeRequestInfo encodeRequestInfoBinary decodeRequestInfoBinary


{-| The typed value of [`ResourceInfo`](#ResourceInfo), to pack and unpack an `Any` with.
-}
resourceInfo : Proto.Message.Message ResourceInfo
resourceInfo =
    Proto.Message.init "google.rpc.ResourceInfo" encodeResourceInfo decodeResourceInfo encodeResourceInfoBinary decodeResourceInfoBinary


{-| The typed value of [`Help`](#Help), to pack and unpack an `Any` with.
-}
help : Proto.Message.Message Help
help =
    Proto.Message.init "google.rpc.Help" encodeHelp decodeHelp encodeHelpBinary decodeHelpBinary


{-| The typed value of [`HelpLink`](#HelpLink), to pack and unpack an `Any` with.
-}
helpLink : Proto.Message.Message HelpLink
helpLink =
    Proto.Message.init "google.rpc.Help.Link" encodeHelpLink decodeHelpLink encodeHelpLinkBinary decodeHelpLinkBinary


{-| The typed value of [`LocalizedMessage`](#LocalizedMessage), to pack and unpack an `Any` with.
-}
localizedMessage : Proto.Message.Message LocalizedMessage
localizedMessage =
    Proto.Message.init "google.rpc.LocalizedMessage" encodeLocalizedMessage decodeLocalizedMessage encodeLocalizedMessageBinary decodeLocalizedMessageBinary



-- REGISTRY


{-| Every message here, to give a client whose calls read error details
that arrive as proto3 JSON ([`Rpc.Client.withRegistry`](Rpc-Client#withRegistry)),
beside the registries its own `Any`s need.
-}
registry : Proto.Registry.Registry
registry =
    Proto.Registry.empty
        |> Proto.Registry.register errorInfo
        |> Proto.Registry.register retryInfo
        |> Proto.Registry.register debugInfo
        |> Proto.Registry.register quotaFailure
        |> Proto.Registry.register quotaFailureViolation
        |> Proto.Registry.register preconditionFailure
        |> Proto.Registry.register preconditionFailureViolation
        |> Proto.Registry.register badRequest
        |> Proto.Registry.register badRequestFieldViolation
        |> Proto.Registry.register requestInfo
        |> Proto.Registry.register resourceInfo
        |> Proto.Registry.register help
        |> Proto.Registry.register helpLink
        |> Proto.Registry.register localizedMessage



-- CODECS


defaultErrorInfo : ErrorInfo
defaultErrorInfo =
    { reason = ""
    , domain = ""
    , metadata = Dict.empty
    }


defaultRetryInfo : RetryInfo
defaultRetryInfo =
    { retryDelay = Nothing
    }


defaultDebugInfo : DebugInfo
defaultDebugInfo =
    { stackEntries = []
    , detail = ""
    }


defaultQuotaFailure : QuotaFailure
defaultQuotaFailure =
    { violations = []
    }


defaultQuotaFailureViolation : QuotaFailureViolation
defaultQuotaFailureViolation =
    { subject = ""
    , description = ""
    , apiService = ""
    , quotaMetric = ""
    , quotaId = ""
    , quotaDimensions = Dict.empty
    , quotaValue = "0"
    , futureQuotaValue = Nothing
    }


defaultPreconditionFailure : PreconditionFailure
defaultPreconditionFailure =
    { violations = []
    }


defaultPreconditionFailureViolation : PreconditionFailureViolation
defaultPreconditionFailureViolation =
    { type_ = ""
    , subject = ""
    , description = ""
    }


defaultBadRequest : BadRequest
defaultBadRequest =
    { fieldViolations = []
    }


defaultBadRequestFieldViolation : BadRequestFieldViolation
defaultBadRequestFieldViolation =
    { field = ""
    , description = ""
    , reason = ""
    , localizedMessage = Nothing
    }


defaultRequestInfo : RequestInfo
defaultRequestInfo =
    { requestId = ""
    , servingData = ""
    }


defaultResourceInfo : ResourceInfo
defaultResourceInfo =
    { resourceType = ""
    , resourceName = ""
    , owner = ""
    , description = ""
    }


defaultHelp : Help
defaultHelp =
    { links = []
    }


defaultHelpLink : HelpLink
defaultHelpLink =
    { description = ""
    , url = ""
    }


defaultLocalizedMessage : LocalizedMessage
defaultLocalizedMessage =
    { locale = ""
    , message = ""
    }


encodeErrorInfo : ErrorInfo -> Proto.Json.Encode.Encoder x
encodeErrorInfo value =
    Proto.Json.Encode.succeed
        (Proto.Json.Encode.object
            [ ( "reason", Proto.Json.Encode.implicit "" Json.Encode.string value.reason )
            , ( "domain", Proto.Json.Encode.implicit "" Json.Encode.string value.domain )
            , ( "metadata", Proto.Json.Encode.dict identity Json.Encode.string value.metadata )
            ]
        )


encodeRetryInfo : RetryInfo -> Proto.Json.Encode.Encoder Proto.Error.Error
encodeRetryInfo value =
    Proto.Json.Encode.checkedObject
        [ Proto.Json.Encode.checkedFields
            [ ( "retryDelay", Proto.Json.Encode.optional Proto.Json.Encode.duration value.retryDelay )
            ]
        ]


encodeDebugInfo : DebugInfo -> Proto.Json.Encode.Encoder x
encodeDebugInfo value =
    Proto.Json.Encode.succeed
        (Proto.Json.Encode.object
            [ ( "stackEntries", Proto.Json.Encode.repeated Json.Encode.string value.stackEntries )
            , ( "detail", Proto.Json.Encode.implicit "" Json.Encode.string value.detail )
            ]
        )


encodeQuotaFailure : QuotaFailure -> Proto.Json.Encode.Encoder x
encodeQuotaFailure value =
    Proto.Json.Encode.succeed
        (Proto.Json.Encode.object
            [ ( "violations", Proto.Json.Encode.totalRepeated encodeQuotaFailureViolation value.violations )
            ]
        )


encodeQuotaFailureViolation : QuotaFailureViolation -> Proto.Json.Encode.Encoder x
encodeQuotaFailureViolation value =
    Proto.Json.Encode.succeed
        (Proto.Json.Encode.object
            [ ( "subject", Proto.Json.Encode.implicit "" Json.Encode.string value.subject )
            , ( "description", Proto.Json.Encode.implicit "" Json.Encode.string value.description )
            , ( "apiService", Proto.Json.Encode.implicit "" Json.Encode.string value.apiService )
            , ( "quotaMetric", Proto.Json.Encode.implicit "" Json.Encode.string value.quotaMetric )
            , ( "quotaId", Proto.Json.Encode.implicit "" Json.Encode.string value.quotaId )
            , ( "quotaDimensions", Proto.Json.Encode.dict identity Json.Encode.string value.quotaDimensions )
            , ( "quotaValue", Proto.Json.Encode.implicit "0" Proto.Json.Encode.int64 value.quotaValue )
            , ( "futureQuotaValue", Maybe.map Proto.Json.Encode.int64 value.futureQuotaValue )
            ]
        )


encodePreconditionFailure : PreconditionFailure -> Proto.Json.Encode.Encoder x
encodePreconditionFailure value =
    Proto.Json.Encode.succeed
        (Proto.Json.Encode.object
            [ ( "violations", Proto.Json.Encode.totalRepeated encodePreconditionFailureViolation value.violations )
            ]
        )


encodePreconditionFailureViolation : PreconditionFailureViolation -> Proto.Json.Encode.Encoder x
encodePreconditionFailureViolation value =
    Proto.Json.Encode.succeed
        (Proto.Json.Encode.object
            [ ( "type", Proto.Json.Encode.implicit "" Json.Encode.string value.type_ )
            , ( "subject", Proto.Json.Encode.implicit "" Json.Encode.string value.subject )
            , ( "description", Proto.Json.Encode.implicit "" Json.Encode.string value.description )
            ]
        )


encodeBadRequest : BadRequest -> Proto.Json.Encode.Encoder x
encodeBadRequest value =
    Proto.Json.Encode.succeed
        (Proto.Json.Encode.object
            [ ( "fieldViolations", Proto.Json.Encode.totalRepeated encodeBadRequestFieldViolation value.fieldViolations )
            ]
        )


encodeBadRequestFieldViolation : BadRequestFieldViolation -> Proto.Json.Encode.Encoder x
encodeBadRequestFieldViolation value =
    Proto.Json.Encode.succeed
        (Proto.Json.Encode.object
            [ ( "field", Proto.Json.Encode.implicit "" Json.Encode.string value.field )
            , ( "description", Proto.Json.Encode.implicit "" Json.Encode.string value.description )
            , ( "reason", Proto.Json.Encode.implicit "" Json.Encode.string value.reason )
            , ( "localizedMessage", Proto.Json.Encode.totalOptional encodeLocalizedMessage value.localizedMessage )
            ]
        )


encodeRequestInfo : RequestInfo -> Proto.Json.Encode.Encoder x
encodeRequestInfo value =
    Proto.Json.Encode.succeed
        (Proto.Json.Encode.object
            [ ( "requestId", Proto.Json.Encode.implicit "" Json.Encode.string value.requestId )
            , ( "servingData", Proto.Json.Encode.implicit "" Json.Encode.string value.servingData )
            ]
        )


encodeResourceInfo : ResourceInfo -> Proto.Json.Encode.Encoder x
encodeResourceInfo value =
    Proto.Json.Encode.succeed
        (Proto.Json.Encode.object
            [ ( "resourceType", Proto.Json.Encode.implicit "" Json.Encode.string value.resourceType )
            , ( "resourceName", Proto.Json.Encode.implicit "" Json.Encode.string value.resourceName )
            , ( "owner", Proto.Json.Encode.implicit "" Json.Encode.string value.owner )
            , ( "description", Proto.Json.Encode.implicit "" Json.Encode.string value.description )
            ]
        )


encodeHelp : Help -> Proto.Json.Encode.Encoder x
encodeHelp value =
    Proto.Json.Encode.succeed
        (Proto.Json.Encode.object
            [ ( "links", Proto.Json.Encode.totalRepeated encodeHelpLink value.links )
            ]
        )


encodeHelpLink : HelpLink -> Proto.Json.Encode.Encoder x
encodeHelpLink value =
    Proto.Json.Encode.succeed
        (Proto.Json.Encode.object
            [ ( "description", Proto.Json.Encode.implicit "" Json.Encode.string value.description )
            , ( "url", Proto.Json.Encode.implicit "" Json.Encode.string value.url )
            ]
        )


encodeLocalizedMessage : LocalizedMessage -> Proto.Json.Encode.Encoder x
encodeLocalizedMessage value =
    Proto.Json.Encode.succeed
        (Proto.Json.Encode.object
            [ ( "locale", Proto.Json.Encode.implicit "" Json.Encode.string value.locale )
            , ( "message", Proto.Json.Encode.implicit "" Json.Encode.string value.message )
            ]
        )


decodeErrorInfo : Json.Decode.Decoder ErrorInfo
decodeErrorInfo =
    Proto.Json.Decode.message
        (Json.Decode.succeed ErrorInfo
            |> Proto.Json.Decode.field "reason" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.field "domain" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.field "metadata" Dict.empty (Proto.Json.Decode.stringDict Proto.Json.Decode.string)
        )


decodeRetryInfo : Json.Decode.Decoder RetryInfo
decodeRetryInfo =
    Proto.Json.Decode.message
        (Json.Decode.succeed RetryInfo
            |> Proto.Json.Decode.fieldEither "retryDelay" "retry_delay" Nothing (Json.Decode.map Just Proto.Json.Decode.duration)
        )


decodeDebugInfo : Json.Decode.Decoder DebugInfo
decodeDebugInfo =
    Proto.Json.Decode.message
        (Json.Decode.succeed DebugInfo
            |> Proto.Json.Decode.fieldEither "stackEntries" "stack_entries" [] (Json.Decode.list Proto.Json.Decode.string)
            |> Proto.Json.Decode.field "detail" "" Proto.Json.Decode.string
        )


decodeQuotaFailure : Json.Decode.Decoder QuotaFailure
decodeQuotaFailure =
    Proto.Json.Decode.message
        (Json.Decode.succeed QuotaFailure
            |> Proto.Json.Decode.field "violations" [] (Json.Decode.list decodeQuotaFailureViolation)
        )


decodeQuotaFailureViolation : Json.Decode.Decoder QuotaFailureViolation
decodeQuotaFailureViolation =
    Proto.Json.Decode.message
        (Json.Decode.succeed QuotaFailureViolation
            |> Proto.Json.Decode.field "subject" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.field "description" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.fieldEither "apiService" "api_service" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.fieldEither "quotaMetric" "quota_metric" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.fieldEither "quotaId" "quota_id" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.fieldEither "quotaDimensions" "quota_dimensions" Dict.empty (Proto.Json.Decode.stringDict Proto.Json.Decode.string)
            |> Proto.Json.Decode.fieldEither "quotaValue" "quota_value" "0" Proto.Json.Decode.int64
            |> Proto.Json.Decode.fieldEither "futureQuotaValue" "future_quota_value" Nothing (Json.Decode.map Just Proto.Json.Decode.int64)
        )


decodePreconditionFailure : Json.Decode.Decoder PreconditionFailure
decodePreconditionFailure =
    Proto.Json.Decode.message
        (Json.Decode.succeed PreconditionFailure
            |> Proto.Json.Decode.field "violations" [] (Json.Decode.list decodePreconditionFailureViolation)
        )


decodePreconditionFailureViolation : Json.Decode.Decoder PreconditionFailureViolation
decodePreconditionFailureViolation =
    Proto.Json.Decode.message
        (Json.Decode.succeed PreconditionFailureViolation
            |> Proto.Json.Decode.field "type" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.field "subject" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.field "description" "" Proto.Json.Decode.string
        )


decodeBadRequest : Json.Decode.Decoder BadRequest
decodeBadRequest =
    Proto.Json.Decode.message
        (Json.Decode.succeed BadRequest
            |> Proto.Json.Decode.fieldEither "fieldViolations" "field_violations" [] (Json.Decode.list decodeBadRequestFieldViolation)
        )


decodeBadRequestFieldViolation : Json.Decode.Decoder BadRequestFieldViolation
decodeBadRequestFieldViolation =
    Proto.Json.Decode.message
        (Json.Decode.succeed BadRequestFieldViolation
            |> Proto.Json.Decode.field "field" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.field "description" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.field "reason" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.fieldEither "localizedMessage" "localized_message" Nothing (Json.Decode.map Just decodeLocalizedMessage)
        )


decodeRequestInfo : Json.Decode.Decoder RequestInfo
decodeRequestInfo =
    Proto.Json.Decode.message
        (Json.Decode.succeed RequestInfo
            |> Proto.Json.Decode.fieldEither "requestId" "request_id" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.fieldEither "servingData" "serving_data" "" Proto.Json.Decode.string
        )


decodeResourceInfo : Json.Decode.Decoder ResourceInfo
decodeResourceInfo =
    Proto.Json.Decode.message
        (Json.Decode.succeed ResourceInfo
            |> Proto.Json.Decode.fieldEither "resourceType" "resource_type" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.fieldEither "resourceName" "resource_name" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.field "owner" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.field "description" "" Proto.Json.Decode.string
        )


decodeHelp : Json.Decode.Decoder Help
decodeHelp =
    Proto.Json.Decode.message
        (Json.Decode.succeed Help
            |> Proto.Json.Decode.field "links" [] (Json.Decode.list decodeHelpLink)
        )


decodeHelpLink : Json.Decode.Decoder HelpLink
decodeHelpLink =
    Proto.Json.Decode.message
        (Json.Decode.succeed HelpLink
            |> Proto.Json.Decode.field "description" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.field "url" "" Proto.Json.Decode.string
        )


decodeLocalizedMessage : Json.Decode.Decoder LocalizedMessage
decodeLocalizedMessage =
    Proto.Json.Decode.message
        (Json.Decode.succeed LocalizedMessage
            |> Proto.Json.Decode.field "locale" "" Proto.Json.Decode.string
            |> Proto.Json.Decode.field "message" "" Proto.Json.Decode.string
        )


encodeErrorInfoBinary : ErrorInfo -> Bytes.Encode.Encoder
encodeErrorInfoBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.reason
        , Proto.Binary.implicit Proto.Binary.string 2 value.domain
        , Proto.Binary.dict Proto.Binary.string Proto.Binary.string 3 value.metadata
        ]


encodeRetryInfoBinary : RetryInfo -> Bytes.Encode.Encoder
encodeRetryInfoBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.optional Proto.Binary.duration 1 value.retryDelay
        ]


encodeDebugInfoBinary : DebugInfo -> Bytes.Encode.Encoder
encodeDebugInfoBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.list Proto.Binary.string 1 value.stackEntries
        , Proto.Binary.implicit Proto.Binary.string 2 value.detail
        ]


encodeQuotaFailureBinary : QuotaFailure -> Bytes.Encode.Encoder
encodeQuotaFailureBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.list (Proto.Binary.embedded encodeQuotaFailureViolationBinary mergeQuotaFailureViolationBinary defaultQuotaFailureViolation) 1 value.violations
        ]


encodeQuotaFailureViolationBinary : QuotaFailureViolation -> Bytes.Encode.Encoder
encodeQuotaFailureViolationBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.subject
        , Proto.Binary.implicit Proto.Binary.string 2 value.description
        , Proto.Binary.implicit Proto.Binary.string 3 value.apiService
        , Proto.Binary.implicit Proto.Binary.string 4 value.quotaMetric
        , Proto.Binary.implicit Proto.Binary.string 5 value.quotaId
        , Proto.Binary.dict Proto.Binary.string Proto.Binary.string 6 value.quotaDimensions
        , Proto.Binary.implicit Proto.Binary.int64 7 value.quotaValue
        , Proto.Binary.optional Proto.Binary.int64 8 value.futureQuotaValue
        ]


encodePreconditionFailureBinary : PreconditionFailure -> Bytes.Encode.Encoder
encodePreconditionFailureBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.list (Proto.Binary.embedded encodePreconditionFailureViolationBinary mergePreconditionFailureViolationBinary defaultPreconditionFailureViolation) 1 value.violations
        ]


encodePreconditionFailureViolationBinary : PreconditionFailureViolation -> Bytes.Encode.Encoder
encodePreconditionFailureViolationBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.type_
        , Proto.Binary.implicit Proto.Binary.string 2 value.subject
        , Proto.Binary.implicit Proto.Binary.string 3 value.description
        ]


encodeBadRequestBinary : BadRequest -> Bytes.Encode.Encoder
encodeBadRequestBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.list (Proto.Binary.embedded encodeBadRequestFieldViolationBinary mergeBadRequestFieldViolationBinary defaultBadRequestFieldViolation) 1 value.fieldViolations
        ]


encodeBadRequestFieldViolationBinary : BadRequestFieldViolation -> Bytes.Encode.Encoder
encodeBadRequestFieldViolationBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.field
        , Proto.Binary.implicit Proto.Binary.string 2 value.description
        , Proto.Binary.implicit Proto.Binary.string 3 value.reason
        , Proto.Binary.optional (Proto.Binary.embedded encodeLocalizedMessageBinary mergeLocalizedMessageBinary defaultLocalizedMessage) 4 value.localizedMessage
        ]


encodeRequestInfoBinary : RequestInfo -> Bytes.Encode.Encoder
encodeRequestInfoBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.requestId
        , Proto.Binary.implicit Proto.Binary.string 2 value.servingData
        ]


encodeResourceInfoBinary : ResourceInfo -> Bytes.Encode.Encoder
encodeResourceInfoBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.resourceType
        , Proto.Binary.implicit Proto.Binary.string 2 value.resourceName
        , Proto.Binary.implicit Proto.Binary.string 3 value.owner
        , Proto.Binary.implicit Proto.Binary.string 4 value.description
        ]


encodeHelpBinary : Help -> Bytes.Encode.Encoder
encodeHelpBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.list (Proto.Binary.embedded encodeHelpLinkBinary mergeHelpLinkBinary defaultHelpLink) 1 value.links
        ]


encodeHelpLinkBinary : HelpLink -> Bytes.Encode.Encoder
encodeHelpLinkBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.description
        , Proto.Binary.implicit Proto.Binary.string 2 value.url
        ]


encodeLocalizedMessageBinary : LocalizedMessage -> Bytes.Encode.Encoder
encodeLocalizedMessageBinary value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.locale
        , Proto.Binary.implicit Proto.Binary.string 2 value.message
        ]


mergeErrorInfoBinary : ErrorInfo -> Proto.Binary.Decoder ErrorInfo
mergeErrorInfoBinary =
    Proto.Binary.merge
        "google.rpc.ErrorInfo"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { reason = v
                            , domain = value.domain
                            , metadata = value.metadata
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { reason = value.reason
                            , domain = v
                            , metadata = value.metadata
                            }
                        )
                        wire
                        value

                3 ->
                    Proto.Binary.mapEntry
                        Proto.Binary.string
                        Proto.Binary.string
                        (\k v ->
                            { reason = value.reason
                            , domain = value.domain
                            , metadata = Dict.insert k v value.metadata
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeErrorInfoBinary : Proto.Binary.Decoder ErrorInfo
decodeErrorInfoBinary =
    mergeErrorInfoBinary defaultErrorInfo


mergeRetryInfoBinary : RetryInfo -> Proto.Binary.Decoder RetryInfo
mergeRetryInfoBinary =
    Proto.Binary.merge
        "google.rpc.RetryInfo"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.duration
                        (\v ->
                            { retryDelay = Just v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeRetryInfoBinary : Proto.Binary.Decoder RetryInfo
decodeRetryInfoBinary =
    mergeRetryInfoBinary defaultRetryInfo


mergeDebugInfoBinary : DebugInfo -> Proto.Binary.Decoder DebugInfo
mergeDebugInfoBinary =
    Proto.Binary.merge
        "google.rpc.DebugInfo"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.repeated
                        Proto.Binary.string
                        (\v ->
                            { stackEntries = v
                            , detail = value.detail
                            }
                        )
                        value.stackEntries
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { stackEntries = value.stackEntries
                            , detail = v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        (\value ->
            { stackEntries = List.reverse value.stackEntries
            , detail = value.detail
            }
        )


decodeDebugInfoBinary : Proto.Binary.Decoder DebugInfo
decodeDebugInfoBinary =
    mergeDebugInfoBinary defaultDebugInfo


mergeQuotaFailureBinary : QuotaFailure -> Proto.Binary.Decoder QuotaFailure
mergeQuotaFailureBinary =
    Proto.Binary.merge
        "google.rpc.QuotaFailure"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.repeated
                        (Proto.Binary.embedded encodeQuotaFailureViolationBinary mergeQuotaFailureViolationBinary defaultQuotaFailureViolation)
                        (\v ->
                            { violations = v
                            }
                        )
                        value.violations
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        (\value ->
            { violations = List.reverse value.violations
            }
        )


decodeQuotaFailureBinary : Proto.Binary.Decoder QuotaFailure
decodeQuotaFailureBinary =
    mergeQuotaFailureBinary defaultQuotaFailure


mergeQuotaFailureViolationBinary : QuotaFailureViolation -> Proto.Binary.Decoder QuotaFailureViolation
mergeQuotaFailureViolationBinary =
    Proto.Binary.merge
        "google.rpc.QuotaFailure.Violation"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { subject = v
                            , description = value.description
                            , apiService = value.apiService
                            , quotaMetric = value.quotaMetric
                            , quotaId = value.quotaId
                            , quotaDimensions = value.quotaDimensions
                            , quotaValue = value.quotaValue
                            , futureQuotaValue = value.futureQuotaValue
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { subject = value.subject
                            , description = v
                            , apiService = value.apiService
                            , quotaMetric = value.quotaMetric
                            , quotaId = value.quotaId
                            , quotaDimensions = value.quotaDimensions
                            , quotaValue = value.quotaValue
                            , futureQuotaValue = value.futureQuotaValue
                            }
                        )
                        wire
                        value

                3 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { subject = value.subject
                            , description = value.description
                            , apiService = v
                            , quotaMetric = value.quotaMetric
                            , quotaId = value.quotaId
                            , quotaDimensions = value.quotaDimensions
                            , quotaValue = value.quotaValue
                            , futureQuotaValue = value.futureQuotaValue
                            }
                        )
                        wire
                        value

                4 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { subject = value.subject
                            , description = value.description
                            , apiService = value.apiService
                            , quotaMetric = v
                            , quotaId = value.quotaId
                            , quotaDimensions = value.quotaDimensions
                            , quotaValue = value.quotaValue
                            , futureQuotaValue = value.futureQuotaValue
                            }
                        )
                        wire
                        value

                5 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { subject = value.subject
                            , description = value.description
                            , apiService = value.apiService
                            , quotaMetric = value.quotaMetric
                            , quotaId = v
                            , quotaDimensions = value.quotaDimensions
                            , quotaValue = value.quotaValue
                            , futureQuotaValue = value.futureQuotaValue
                            }
                        )
                        wire
                        value

                6 ->
                    Proto.Binary.mapEntry
                        Proto.Binary.string
                        Proto.Binary.string
                        (\k v ->
                            { subject = value.subject
                            , description = value.description
                            , apiService = value.apiService
                            , quotaMetric = value.quotaMetric
                            , quotaId = value.quotaId
                            , quotaDimensions = Dict.insert k v value.quotaDimensions
                            , quotaValue = value.quotaValue
                            , futureQuotaValue = value.futureQuotaValue
                            }
                        )
                        wire
                        value

                7 ->
                    Proto.Binary.field
                        Proto.Binary.int64
                        (\v ->
                            { subject = value.subject
                            , description = value.description
                            , apiService = value.apiService
                            , quotaMetric = value.quotaMetric
                            , quotaId = value.quotaId
                            , quotaDimensions = value.quotaDimensions
                            , quotaValue = v
                            , futureQuotaValue = value.futureQuotaValue
                            }
                        )
                        wire
                        value

                8 ->
                    Proto.Binary.field
                        Proto.Binary.int64
                        (\v ->
                            { subject = value.subject
                            , description = value.description
                            , apiService = value.apiService
                            , quotaMetric = value.quotaMetric
                            , quotaId = value.quotaId
                            , quotaDimensions = value.quotaDimensions
                            , quotaValue = value.quotaValue
                            , futureQuotaValue = Just v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeQuotaFailureViolationBinary : Proto.Binary.Decoder QuotaFailureViolation
decodeQuotaFailureViolationBinary =
    mergeQuotaFailureViolationBinary defaultQuotaFailureViolation


mergePreconditionFailureBinary : PreconditionFailure -> Proto.Binary.Decoder PreconditionFailure
mergePreconditionFailureBinary =
    Proto.Binary.merge
        "google.rpc.PreconditionFailure"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.repeated
                        (Proto.Binary.embedded encodePreconditionFailureViolationBinary mergePreconditionFailureViolationBinary defaultPreconditionFailureViolation)
                        (\v ->
                            { violations = v
                            }
                        )
                        value.violations
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        (\value ->
            { violations = List.reverse value.violations
            }
        )


decodePreconditionFailureBinary : Proto.Binary.Decoder PreconditionFailure
decodePreconditionFailureBinary =
    mergePreconditionFailureBinary defaultPreconditionFailure


mergePreconditionFailureViolationBinary : PreconditionFailureViolation -> Proto.Binary.Decoder PreconditionFailureViolation
mergePreconditionFailureViolationBinary =
    Proto.Binary.merge
        "google.rpc.PreconditionFailure.Violation"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { type_ = v
                            , subject = value.subject
                            , description = value.description
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { type_ = value.type_
                            , subject = v
                            , description = value.description
                            }
                        )
                        wire
                        value

                3 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { type_ = value.type_
                            , subject = value.subject
                            , description = v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodePreconditionFailureViolationBinary : Proto.Binary.Decoder PreconditionFailureViolation
decodePreconditionFailureViolationBinary =
    mergePreconditionFailureViolationBinary defaultPreconditionFailureViolation


mergeBadRequestBinary : BadRequest -> Proto.Binary.Decoder BadRequest
mergeBadRequestBinary =
    Proto.Binary.merge
        "google.rpc.BadRequest"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.repeated
                        (Proto.Binary.embedded encodeBadRequestFieldViolationBinary mergeBadRequestFieldViolationBinary defaultBadRequestFieldViolation)
                        (\v ->
                            { fieldViolations = v
                            }
                        )
                        value.fieldViolations
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        (\value ->
            { fieldViolations = List.reverse value.fieldViolations
            }
        )


decodeBadRequestBinary : Proto.Binary.Decoder BadRequest
decodeBadRequestBinary =
    mergeBadRequestBinary defaultBadRequest


mergeBadRequestFieldViolationBinary : BadRequestFieldViolation -> Proto.Binary.Decoder BadRequestFieldViolation
mergeBadRequestFieldViolationBinary =
    Proto.Binary.merge
        "google.rpc.BadRequest.FieldViolation"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { field = v
                            , description = value.description
                            , reason = value.reason
                            , localizedMessage = value.localizedMessage
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { field = value.field
                            , description = v
                            , reason = value.reason
                            , localizedMessage = value.localizedMessage
                            }
                        )
                        wire
                        value

                3 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { field = value.field
                            , description = value.description
                            , reason = v
                            , localizedMessage = value.localizedMessage
                            }
                        )
                        wire
                        value

                4 ->
                    Proto.Binary.fieldInto
                        (Proto.Binary.embedded encodeLocalizedMessageBinary mergeLocalizedMessageBinary defaultLocalizedMessage)
                        value.localizedMessage
                        (\v ->
                            { field = value.field
                            , description = value.description
                            , reason = value.reason
                            , localizedMessage = Just v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeBadRequestFieldViolationBinary : Proto.Binary.Decoder BadRequestFieldViolation
decodeBadRequestFieldViolationBinary =
    mergeBadRequestFieldViolationBinary defaultBadRequestFieldViolation


mergeRequestInfoBinary : RequestInfo -> Proto.Binary.Decoder RequestInfo
mergeRequestInfoBinary =
    Proto.Binary.merge
        "google.rpc.RequestInfo"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { requestId = v
                            , servingData = value.servingData
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { requestId = value.requestId
                            , servingData = v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeRequestInfoBinary : Proto.Binary.Decoder RequestInfo
decodeRequestInfoBinary =
    mergeRequestInfoBinary defaultRequestInfo


mergeResourceInfoBinary : ResourceInfo -> Proto.Binary.Decoder ResourceInfo
mergeResourceInfoBinary =
    Proto.Binary.merge
        "google.rpc.ResourceInfo"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { resourceType = v
                            , resourceName = value.resourceName
                            , owner = value.owner
                            , description = value.description
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { resourceType = value.resourceType
                            , resourceName = v
                            , owner = value.owner
                            , description = value.description
                            }
                        )
                        wire
                        value

                3 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { resourceType = value.resourceType
                            , resourceName = value.resourceName
                            , owner = v
                            , description = value.description
                            }
                        )
                        wire
                        value

                4 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { resourceType = value.resourceType
                            , resourceName = value.resourceName
                            , owner = value.owner
                            , description = v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeResourceInfoBinary : Proto.Binary.Decoder ResourceInfo
decodeResourceInfoBinary =
    mergeResourceInfoBinary defaultResourceInfo


mergeHelpBinary : Help -> Proto.Binary.Decoder Help
mergeHelpBinary =
    Proto.Binary.merge
        "google.rpc.Help"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.repeated
                        (Proto.Binary.embedded encodeHelpLinkBinary mergeHelpLinkBinary defaultHelpLink)
                        (\v ->
                            { links = v
                            }
                        )
                        value.links
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        (\value ->
            { links = List.reverse value.links
            }
        )


decodeHelpBinary : Proto.Binary.Decoder Help
decodeHelpBinary =
    mergeHelpBinary defaultHelp


mergeHelpLinkBinary : HelpLink -> Proto.Binary.Decoder HelpLink
mergeHelpLinkBinary =
    Proto.Binary.merge
        "google.rpc.Help.Link"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { description = v
                            , url = value.url
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { description = value.description
                            , url = v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeHelpLinkBinary : Proto.Binary.Decoder HelpLink
decodeHelpLinkBinary =
    mergeHelpLinkBinary defaultHelpLink


mergeLocalizedMessageBinary : LocalizedMessage -> Proto.Binary.Decoder LocalizedMessage
mergeLocalizedMessageBinary =
    Proto.Binary.merge
        "google.rpc.LocalizedMessage"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { locale = v
                            , message = value.message
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { locale = value.locale
                            , message = v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeLocalizedMessageBinary : Proto.Binary.Decoder LocalizedMessage
decodeLocalizedMessageBinary =
    mergeLocalizedMessageBinary defaultLocalizedMessage
