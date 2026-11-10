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
([`Rpc.withRegistry`](Rpc#withRegistry)), or the details read as
[`UnregisteredType`](Rpc-Error#DetailProblem).

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
import Proto.Duration exposing (Duration)
import Proto.Json
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
    { retryDelay : Maybe Duration
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
    Proto.Message.init "google.rpc.ErrorInfo" encodeErrorInfo decodeErrorInfo encodeErrorInfoBytes decodeErrorInfoBytes


{-| The typed value of [`RetryInfo`](#RetryInfo), to pack and unpack an `Any` with.
-}
retryInfo : Proto.Message.Message RetryInfo
retryInfo =
    Proto.Message.init "google.rpc.RetryInfo" encodeRetryInfo decodeRetryInfo encodeRetryInfoBytes decodeRetryInfoBytes


{-| The typed value of [`DebugInfo`](#DebugInfo), to pack and unpack an `Any` with.
-}
debugInfo : Proto.Message.Message DebugInfo
debugInfo =
    Proto.Message.init "google.rpc.DebugInfo" encodeDebugInfo decodeDebugInfo encodeDebugInfoBytes decodeDebugInfoBytes


{-| The typed value of [`QuotaFailure`](#QuotaFailure), to pack and unpack an `Any` with.
-}
quotaFailure : Proto.Message.Message QuotaFailure
quotaFailure =
    Proto.Message.init "google.rpc.QuotaFailure" encodeQuotaFailure decodeQuotaFailure encodeQuotaFailureBytes decodeQuotaFailureBytes


{-| The typed value of [`QuotaFailureViolation`](#QuotaFailureViolation), to pack and unpack an `Any` with.
-}
quotaFailureViolation : Proto.Message.Message QuotaFailureViolation
quotaFailureViolation =
    Proto.Message.init "google.rpc.QuotaFailure.Violation" encodeQuotaFailureViolation decodeQuotaFailureViolation encodeQuotaFailureViolationBytes decodeQuotaFailureViolationBytes


{-| The typed value of [`PreconditionFailure`](#PreconditionFailure), to pack and unpack an `Any` with.
-}
preconditionFailure : Proto.Message.Message PreconditionFailure
preconditionFailure =
    Proto.Message.init "google.rpc.PreconditionFailure" encodePreconditionFailure decodePreconditionFailure encodePreconditionFailureBytes decodePreconditionFailureBytes


{-| The typed value of [`PreconditionFailureViolation`](#PreconditionFailureViolation), to pack and unpack an `Any` with.
-}
preconditionFailureViolation : Proto.Message.Message PreconditionFailureViolation
preconditionFailureViolation =
    Proto.Message.init "google.rpc.PreconditionFailure.Violation" encodePreconditionFailureViolation decodePreconditionFailureViolation encodePreconditionFailureViolationBytes decodePreconditionFailureViolationBytes


{-| The typed value of [`BadRequest`](#BadRequest), to pack and unpack an `Any` with.
-}
badRequest : Proto.Message.Message BadRequest
badRequest =
    Proto.Message.init "google.rpc.BadRequest" encodeBadRequest decodeBadRequest encodeBadRequestBytes decodeBadRequestBytes


{-| The typed value of [`BadRequestFieldViolation`](#BadRequestFieldViolation), to pack and unpack an `Any` with.
-}
badRequestFieldViolation : Proto.Message.Message BadRequestFieldViolation
badRequestFieldViolation =
    Proto.Message.init "google.rpc.BadRequest.FieldViolation" encodeBadRequestFieldViolation decodeBadRequestFieldViolation encodeBadRequestFieldViolationBytes decodeBadRequestFieldViolationBytes


{-| The typed value of [`RequestInfo`](#RequestInfo), to pack and unpack an `Any` with.
-}
requestInfo : Proto.Message.Message RequestInfo
requestInfo =
    Proto.Message.init "google.rpc.RequestInfo" encodeRequestInfo decodeRequestInfo encodeRequestInfoBytes decodeRequestInfoBytes


{-| The typed value of [`ResourceInfo`](#ResourceInfo), to pack and unpack an `Any` with.
-}
resourceInfo : Proto.Message.Message ResourceInfo
resourceInfo =
    Proto.Message.init "google.rpc.ResourceInfo" encodeResourceInfo decodeResourceInfo encodeResourceInfoBytes decodeResourceInfoBytes


{-| The typed value of [`Help`](#Help), to pack and unpack an `Any` with.
-}
help : Proto.Message.Message Help
help =
    Proto.Message.init "google.rpc.Help" encodeHelp decodeHelp encodeHelpBytes decodeHelpBytes


{-| The typed value of [`HelpLink`](#HelpLink), to pack and unpack an `Any` with.
-}
helpLink : Proto.Message.Message HelpLink
helpLink =
    Proto.Message.init "google.rpc.Help.Link" encodeHelpLink decodeHelpLink encodeHelpLinkBytes decodeHelpLinkBytes


{-| The typed value of [`LocalizedMessage`](#LocalizedMessage), to pack and unpack an `Any` with.
-}
localizedMessage : Proto.Message.Message LocalizedMessage
localizedMessage =
    Proto.Message.init "google.rpc.LocalizedMessage" encodeLocalizedMessage decodeLocalizedMessage encodeLocalizedMessageBytes decodeLocalizedMessageBytes



-- REGISTRY


{-| Every message here, to give a client whose calls read error details
that arrive as proto3 JSON ([`Rpc.withRegistry`](Rpc#withRegistry)),
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


encodeErrorInfo : ErrorInfo -> Json.Encode.Value
encodeErrorInfo value =
    Proto.Json.objectOfFields
        [ ( "reason", Proto.Json.implicitField "" Json.Encode.string value.reason )
        , ( "domain", Proto.Json.implicitField "" Json.Encode.string value.domain )
        , ( "metadata", Proto.Json.dictField identity Json.Encode.string value.metadata )
        ]


encodeRetryInfo : RetryInfo -> Json.Encode.Value
encodeRetryInfo value =
    Proto.Json.objectOfFields
        [ ( "retryDelay", Maybe.map Proto.Json.encodeDuration value.retryDelay )
        ]


encodeDebugInfo : DebugInfo -> Json.Encode.Value
encodeDebugInfo value =
    Proto.Json.objectOfFields
        [ ( "stackEntries", Proto.Json.repeatedField Json.Encode.string value.stackEntries )
        , ( "detail", Proto.Json.implicitField "" Json.Encode.string value.detail )
        ]


encodeQuotaFailure : QuotaFailure -> Json.Encode.Value
encodeQuotaFailure value =
    Proto.Json.objectOfFields
        [ ( "violations", Proto.Json.repeatedField encodeQuotaFailureViolation value.violations )
        ]


encodeQuotaFailureViolation : QuotaFailureViolation -> Json.Encode.Value
encodeQuotaFailureViolation value =
    Proto.Json.objectOfFields
        [ ( "subject", Proto.Json.implicitField "" Json.Encode.string value.subject )
        , ( "description", Proto.Json.implicitField "" Json.Encode.string value.description )
        , ( "apiService", Proto.Json.implicitField "" Json.Encode.string value.apiService )
        , ( "quotaMetric", Proto.Json.implicitField "" Json.Encode.string value.quotaMetric )
        , ( "quotaId", Proto.Json.implicitField "" Json.Encode.string value.quotaId )
        , ( "quotaDimensions", Proto.Json.dictField identity Json.Encode.string value.quotaDimensions )
        , ( "quotaValue", Proto.Json.implicitField "0" Proto.Json.encodeInt64 value.quotaValue )
        , ( "futureQuotaValue", Maybe.map Proto.Json.encodeInt64 value.futureQuotaValue )
        ]


encodePreconditionFailure : PreconditionFailure -> Json.Encode.Value
encodePreconditionFailure value =
    Proto.Json.objectOfFields
        [ ( "violations", Proto.Json.repeatedField encodePreconditionFailureViolation value.violations )
        ]


encodePreconditionFailureViolation : PreconditionFailureViolation -> Json.Encode.Value
encodePreconditionFailureViolation value =
    Proto.Json.objectOfFields
        [ ( "type", Proto.Json.implicitField "" Json.Encode.string value.type_ )
        , ( "subject", Proto.Json.implicitField "" Json.Encode.string value.subject )
        , ( "description", Proto.Json.implicitField "" Json.Encode.string value.description )
        ]


encodeBadRequest : BadRequest -> Json.Encode.Value
encodeBadRequest value =
    Proto.Json.objectOfFields
        [ ( "fieldViolations", Proto.Json.repeatedField encodeBadRequestFieldViolation value.fieldViolations )
        ]


encodeBadRequestFieldViolation : BadRequestFieldViolation -> Json.Encode.Value
encodeBadRequestFieldViolation value =
    Proto.Json.objectOfFields
        [ ( "field", Proto.Json.implicitField "" Json.Encode.string value.field )
        , ( "description", Proto.Json.implicitField "" Json.Encode.string value.description )
        , ( "reason", Proto.Json.implicitField "" Json.Encode.string value.reason )
        , ( "localizedMessage", Maybe.map encodeLocalizedMessage value.localizedMessage )
        ]


encodeRequestInfo : RequestInfo -> Json.Encode.Value
encodeRequestInfo value =
    Proto.Json.objectOfFields
        [ ( "requestId", Proto.Json.implicitField "" Json.Encode.string value.requestId )
        , ( "servingData", Proto.Json.implicitField "" Json.Encode.string value.servingData )
        ]


encodeResourceInfo : ResourceInfo -> Json.Encode.Value
encodeResourceInfo value =
    Proto.Json.objectOfFields
        [ ( "resourceType", Proto.Json.implicitField "" Json.Encode.string value.resourceType )
        , ( "resourceName", Proto.Json.implicitField "" Json.Encode.string value.resourceName )
        , ( "owner", Proto.Json.implicitField "" Json.Encode.string value.owner )
        , ( "description", Proto.Json.implicitField "" Json.Encode.string value.description )
        ]


encodeHelp : Help -> Json.Encode.Value
encodeHelp value =
    Proto.Json.objectOfFields
        [ ( "links", Proto.Json.repeatedField encodeHelpLink value.links )
        ]


encodeHelpLink : HelpLink -> Json.Encode.Value
encodeHelpLink value =
    Proto.Json.objectOfFields
        [ ( "description", Proto.Json.implicitField "" Json.Encode.string value.description )
        , ( "url", Proto.Json.implicitField "" Json.Encode.string value.url )
        ]


encodeLocalizedMessage : LocalizedMessage -> Json.Encode.Value
encodeLocalizedMessage value =
    Proto.Json.objectOfFields
        [ ( "locale", Proto.Json.implicitField "" Json.Encode.string value.locale )
        , ( "message", Proto.Json.implicitField "" Json.Encode.string value.message )
        ]


decodeErrorInfo : Json.Decode.Decoder ErrorInfo
decodeErrorInfo =
    Json.Decode.succeed ErrorInfo
        |> Proto.Json.field "reason" "" Proto.Json.string
        |> Proto.Json.field "domain" "" Proto.Json.string
        |> Proto.Json.field "metadata" Dict.empty (Proto.Json.stringDict Proto.Json.string)


decodeRetryInfo : Json.Decode.Decoder RetryInfo
decodeRetryInfo =
    Json.Decode.succeed RetryInfo
        |> Proto.Json.fieldEither "retryDelay" "retry_delay" Nothing (Json.Decode.map Just Proto.Json.duration)


decodeDebugInfo : Json.Decode.Decoder DebugInfo
decodeDebugInfo =
    Json.Decode.succeed DebugInfo
        |> Proto.Json.fieldEither "stackEntries" "stack_entries" [] (Json.Decode.list Proto.Json.string)
        |> Proto.Json.field "detail" "" Proto.Json.string


decodeQuotaFailure : Json.Decode.Decoder QuotaFailure
decodeQuotaFailure =
    Json.Decode.succeed QuotaFailure
        |> Proto.Json.field "violations" [] (Json.Decode.list decodeQuotaFailureViolation)


decodeQuotaFailureViolation : Json.Decode.Decoder QuotaFailureViolation
decodeQuotaFailureViolation =
    Json.Decode.succeed QuotaFailureViolation
        |> Proto.Json.field "subject" "" Proto.Json.string
        |> Proto.Json.field "description" "" Proto.Json.string
        |> Proto.Json.fieldEither "apiService" "api_service" "" Proto.Json.string
        |> Proto.Json.fieldEither "quotaMetric" "quota_metric" "" Proto.Json.string
        |> Proto.Json.fieldEither "quotaId" "quota_id" "" Proto.Json.string
        |> Proto.Json.fieldEither "quotaDimensions" "quota_dimensions" Dict.empty (Proto.Json.stringDict Proto.Json.string)
        |> Proto.Json.fieldEither "quotaValue" "quota_value" "0" Proto.Json.int64
        |> Proto.Json.fieldEither "futureQuotaValue" "future_quota_value" Nothing (Json.Decode.map Just Proto.Json.int64)


decodePreconditionFailure : Json.Decode.Decoder PreconditionFailure
decodePreconditionFailure =
    Json.Decode.succeed PreconditionFailure
        |> Proto.Json.field "violations" [] (Json.Decode.list decodePreconditionFailureViolation)


decodePreconditionFailureViolation : Json.Decode.Decoder PreconditionFailureViolation
decodePreconditionFailureViolation =
    Json.Decode.succeed PreconditionFailureViolation
        |> Proto.Json.field "type" "" Proto.Json.string
        |> Proto.Json.field "subject" "" Proto.Json.string
        |> Proto.Json.field "description" "" Proto.Json.string


decodeBadRequest : Json.Decode.Decoder BadRequest
decodeBadRequest =
    Json.Decode.succeed BadRequest
        |> Proto.Json.fieldEither "fieldViolations" "field_violations" [] (Json.Decode.list decodeBadRequestFieldViolation)


decodeBadRequestFieldViolation : Json.Decode.Decoder BadRequestFieldViolation
decodeBadRequestFieldViolation =
    Json.Decode.succeed BadRequestFieldViolation
        |> Proto.Json.field "field" "" Proto.Json.string
        |> Proto.Json.field "description" "" Proto.Json.string
        |> Proto.Json.field "reason" "" Proto.Json.string
        |> Proto.Json.fieldEither "localizedMessage" "localized_message" Nothing (Json.Decode.map Just decodeLocalizedMessage)


decodeRequestInfo : Json.Decode.Decoder RequestInfo
decodeRequestInfo =
    Json.Decode.succeed RequestInfo
        |> Proto.Json.fieldEither "requestId" "request_id" "" Proto.Json.string
        |> Proto.Json.fieldEither "servingData" "serving_data" "" Proto.Json.string


decodeResourceInfo : Json.Decode.Decoder ResourceInfo
decodeResourceInfo =
    Json.Decode.succeed ResourceInfo
        |> Proto.Json.fieldEither "resourceType" "resource_type" "" Proto.Json.string
        |> Proto.Json.fieldEither "resourceName" "resource_name" "" Proto.Json.string
        |> Proto.Json.field "owner" "" Proto.Json.string
        |> Proto.Json.field "description" "" Proto.Json.string


decodeHelp : Json.Decode.Decoder Help
decodeHelp =
    Json.Decode.succeed Help
        |> Proto.Json.field "links" [] (Json.Decode.list decodeHelpLink)


decodeHelpLink : Json.Decode.Decoder HelpLink
decodeHelpLink =
    Json.Decode.succeed HelpLink
        |> Proto.Json.field "description" "" Proto.Json.string
        |> Proto.Json.field "url" "" Proto.Json.string


decodeLocalizedMessage : Json.Decode.Decoder LocalizedMessage
decodeLocalizedMessage =
    Json.Decode.succeed LocalizedMessage
        |> Proto.Json.field "locale" "" Proto.Json.string
        |> Proto.Json.field "message" "" Proto.Json.string


encodeErrorInfoBytes : ErrorInfo -> Bytes.Encode.Encoder
encodeErrorInfoBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.reason
        , Proto.Binary.implicit Proto.Binary.string 2 value.domain
        , Proto.Binary.dict Proto.Binary.string Proto.Binary.string 3 value.metadata
        ]


encodeRetryInfoBytes : RetryInfo -> Bytes.Encode.Encoder
encodeRetryInfoBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.optional Proto.Binary.duration 1 value.retryDelay
        ]


encodeDebugInfoBytes : DebugInfo -> Bytes.Encode.Encoder
encodeDebugInfoBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.list Proto.Binary.string 1 value.stackEntries
        , Proto.Binary.implicit Proto.Binary.string 2 value.detail
        ]


encodeQuotaFailureBytes : QuotaFailure -> Bytes.Encode.Encoder
encodeQuotaFailureBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.list (Proto.Binary.embedded encodeQuotaFailureViolationBytes mergeQuotaFailureViolationBytes defaultQuotaFailureViolation) 1 value.violations
        ]


encodeQuotaFailureViolationBytes : QuotaFailureViolation -> Bytes.Encode.Encoder
encodeQuotaFailureViolationBytes value =
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


encodePreconditionFailureBytes : PreconditionFailure -> Bytes.Encode.Encoder
encodePreconditionFailureBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.list (Proto.Binary.embedded encodePreconditionFailureViolationBytes mergePreconditionFailureViolationBytes defaultPreconditionFailureViolation) 1 value.violations
        ]


encodePreconditionFailureViolationBytes : PreconditionFailureViolation -> Bytes.Encode.Encoder
encodePreconditionFailureViolationBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.type_
        , Proto.Binary.implicit Proto.Binary.string 2 value.subject
        , Proto.Binary.implicit Proto.Binary.string 3 value.description
        ]


encodeBadRequestBytes : BadRequest -> Bytes.Encode.Encoder
encodeBadRequestBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.list (Proto.Binary.embedded encodeBadRequestFieldViolationBytes mergeBadRequestFieldViolationBytes defaultBadRequestFieldViolation) 1 value.fieldViolations
        ]


encodeBadRequestFieldViolationBytes : BadRequestFieldViolation -> Bytes.Encode.Encoder
encodeBadRequestFieldViolationBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.field
        , Proto.Binary.implicit Proto.Binary.string 2 value.description
        , Proto.Binary.implicit Proto.Binary.string 3 value.reason
        , Proto.Binary.optional (Proto.Binary.embedded encodeLocalizedMessageBytes mergeLocalizedMessageBytes defaultLocalizedMessage) 4 value.localizedMessage
        ]


encodeRequestInfoBytes : RequestInfo -> Bytes.Encode.Encoder
encodeRequestInfoBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.requestId
        , Proto.Binary.implicit Proto.Binary.string 2 value.servingData
        ]


encodeResourceInfoBytes : ResourceInfo -> Bytes.Encode.Encoder
encodeResourceInfoBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.resourceType
        , Proto.Binary.implicit Proto.Binary.string 2 value.resourceName
        , Proto.Binary.implicit Proto.Binary.string 3 value.owner
        , Proto.Binary.implicit Proto.Binary.string 4 value.description
        ]


encodeHelpBytes : Help -> Bytes.Encode.Encoder
encodeHelpBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.list (Proto.Binary.embedded encodeHelpLinkBytes mergeHelpLinkBytes defaultHelpLink) 1 value.links
        ]


encodeHelpLinkBytes : HelpLink -> Bytes.Encode.Encoder
encodeHelpLinkBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.description
        , Proto.Binary.implicit Proto.Binary.string 2 value.url
        ]


encodeLocalizedMessageBytes : LocalizedMessage -> Bytes.Encode.Encoder
encodeLocalizedMessageBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.locale
        , Proto.Binary.implicit Proto.Binary.string 2 value.message
        ]


mergeErrorInfoBytes : ErrorInfo -> Proto.Binary.Decoder ErrorInfo
mergeErrorInfoBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | reason = v
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | domain = v
                            }
                        )
                        wire
                        value

                3 ->
                    Proto.Binary.mapEntry
                        Proto.Binary.string
                        Proto.Binary.string
                        (\k v ->
                            { value
                                | metadata = Dict.insert k v value.metadata
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeErrorInfoBytes : Proto.Binary.Decoder ErrorInfo
decodeErrorInfoBytes =
    mergeErrorInfoBytes defaultErrorInfo


mergeRetryInfoBytes : RetryInfo -> Proto.Binary.Decoder RetryInfo
mergeRetryInfoBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.duration
                        (\v ->
                            { value
                                | retryDelay = Just v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeRetryInfoBytes : Proto.Binary.Decoder RetryInfo
decodeRetryInfoBytes =
    mergeRetryInfoBytes defaultRetryInfo


mergeDebugInfoBytes : DebugInfo -> Proto.Binary.Decoder DebugInfo
mergeDebugInfoBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.repeated
                        Proto.Binary.string
                        (\v ->
                            { value
                                | stackEntries = v
                            }
                        )
                        value.stackEntries
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | detail = v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        (\value ->
            { value
                | stackEntries = List.reverse value.stackEntries
            }
        )


decodeDebugInfoBytes : Proto.Binary.Decoder DebugInfo
decodeDebugInfoBytes =
    mergeDebugInfoBytes defaultDebugInfo


mergeQuotaFailureBytes : QuotaFailure -> Proto.Binary.Decoder QuotaFailure
mergeQuotaFailureBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.repeated
                        (Proto.Binary.embedded encodeQuotaFailureViolationBytes mergeQuotaFailureViolationBytes defaultQuotaFailureViolation)
                        (\v ->
                            { value
                                | violations = v
                            }
                        )
                        value.violations
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        (\value ->
            { value
                | violations = List.reverse value.violations
            }
        )


decodeQuotaFailureBytes : Proto.Binary.Decoder QuotaFailure
decodeQuotaFailureBytes =
    mergeQuotaFailureBytes defaultQuotaFailure


mergeQuotaFailureViolationBytes : QuotaFailureViolation -> Proto.Binary.Decoder QuotaFailureViolation
mergeQuotaFailureViolationBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | subject = v
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | description = v
                            }
                        )
                        wire
                        value

                3 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | apiService = v
                            }
                        )
                        wire
                        value

                4 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | quotaMetric = v
                            }
                        )
                        wire
                        value

                5 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | quotaId = v
                            }
                        )
                        wire
                        value

                6 ->
                    Proto.Binary.mapEntry
                        Proto.Binary.string
                        Proto.Binary.string
                        (\k v ->
                            { value
                                | quotaDimensions = Dict.insert k v value.quotaDimensions
                            }
                        )
                        wire
                        value

                7 ->
                    Proto.Binary.field
                        Proto.Binary.int64
                        (\v ->
                            { value
                                | quotaValue = v
                            }
                        )
                        wire
                        value

                8 ->
                    Proto.Binary.field
                        Proto.Binary.int64
                        (\v ->
                            { value
                                | futureQuotaValue = Just v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeQuotaFailureViolationBytes : Proto.Binary.Decoder QuotaFailureViolation
decodeQuotaFailureViolationBytes =
    mergeQuotaFailureViolationBytes defaultQuotaFailureViolation


mergePreconditionFailureBytes : PreconditionFailure -> Proto.Binary.Decoder PreconditionFailure
mergePreconditionFailureBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.repeated
                        (Proto.Binary.embedded encodePreconditionFailureViolationBytes mergePreconditionFailureViolationBytes defaultPreconditionFailureViolation)
                        (\v ->
                            { value
                                | violations = v
                            }
                        )
                        value.violations
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        (\value ->
            { value
                | violations = List.reverse value.violations
            }
        )


decodePreconditionFailureBytes : Proto.Binary.Decoder PreconditionFailure
decodePreconditionFailureBytes =
    mergePreconditionFailureBytes defaultPreconditionFailure


mergePreconditionFailureViolationBytes : PreconditionFailureViolation -> Proto.Binary.Decoder PreconditionFailureViolation
mergePreconditionFailureViolationBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | type_ = v
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | subject = v
                            }
                        )
                        wire
                        value

                3 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | description = v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodePreconditionFailureViolationBytes : Proto.Binary.Decoder PreconditionFailureViolation
decodePreconditionFailureViolationBytes =
    mergePreconditionFailureViolationBytes defaultPreconditionFailureViolation


mergeBadRequestBytes : BadRequest -> Proto.Binary.Decoder BadRequest
mergeBadRequestBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.repeated
                        (Proto.Binary.embedded encodeBadRequestFieldViolationBytes mergeBadRequestFieldViolationBytes defaultBadRequestFieldViolation)
                        (\v ->
                            { value
                                | fieldViolations = v
                            }
                        )
                        value.fieldViolations
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        (\value ->
            { value
                | fieldViolations = List.reverse value.fieldViolations
            }
        )


decodeBadRequestBytes : Proto.Binary.Decoder BadRequest
decodeBadRequestBytes =
    mergeBadRequestBytes defaultBadRequest


mergeBadRequestFieldViolationBytes : BadRequestFieldViolation -> Proto.Binary.Decoder BadRequestFieldViolation
mergeBadRequestFieldViolationBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | field = v
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | description = v
                            }
                        )
                        wire
                        value

                3 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | reason = v
                            }
                        )
                        wire
                        value

                4 ->
                    Proto.Binary.fieldInto
                        (Proto.Binary.embedded encodeLocalizedMessageBytes mergeLocalizedMessageBytes defaultLocalizedMessage)
                        value.localizedMessage
                        (\v ->
                            { value
                                | localizedMessage = Just v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeBadRequestFieldViolationBytes : Proto.Binary.Decoder BadRequestFieldViolation
decodeBadRequestFieldViolationBytes =
    mergeBadRequestFieldViolationBytes defaultBadRequestFieldViolation


mergeRequestInfoBytes : RequestInfo -> Proto.Binary.Decoder RequestInfo
mergeRequestInfoBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | requestId = v
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | servingData = v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeRequestInfoBytes : Proto.Binary.Decoder RequestInfo
decodeRequestInfoBytes =
    mergeRequestInfoBytes defaultRequestInfo


mergeResourceInfoBytes : ResourceInfo -> Proto.Binary.Decoder ResourceInfo
mergeResourceInfoBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | resourceType = v
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | resourceName = v
                            }
                        )
                        wire
                        value

                3 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | owner = v
                            }
                        )
                        wire
                        value

                4 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | description = v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeResourceInfoBytes : Proto.Binary.Decoder ResourceInfo
decodeResourceInfoBytes =
    mergeResourceInfoBytes defaultResourceInfo


mergeHelpBytes : Help -> Proto.Binary.Decoder Help
mergeHelpBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.repeated
                        (Proto.Binary.embedded encodeHelpLinkBytes mergeHelpLinkBytes defaultHelpLink)
                        (\v ->
                            { value
                                | links = v
                            }
                        )
                        value.links
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        (\value ->
            { value
                | links = List.reverse value.links
            }
        )


decodeHelpBytes : Proto.Binary.Decoder Help
decodeHelpBytes =
    mergeHelpBytes defaultHelp


mergeHelpLinkBytes : HelpLink -> Proto.Binary.Decoder HelpLink
mergeHelpLinkBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | description = v
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | url = v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeHelpLinkBytes : Proto.Binary.Decoder HelpLink
decodeHelpLinkBytes =
    mergeHelpLinkBytes defaultHelpLink


mergeLocalizedMessageBytes : LocalizedMessage -> Proto.Binary.Decoder LocalizedMessage
mergeLocalizedMessageBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | locale = v
                            }
                        )
                        wire
                        value

                2 ->
                    Proto.Binary.field
                        Proto.Binary.string
                        (\v ->
                            { value
                                | message = v
                            }
                        )
                        wire
                        value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


decodeLocalizedMessageBytes : Proto.Binary.Decoder LocalizedMessage
decodeLocalizedMessageBytes =
    mergeLocalizedMessageBytes defaultLocalizedMessage
