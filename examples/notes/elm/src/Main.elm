module Main exposing (main)

{-| The notes example: list, create, edit, archive and delete notes through the
generated `Notes.V1.NotesService`, over Connect or over HTTP transcoding, and
show what each call sent and how it failed. `examples/notes/README.md` walks
through it.
-}

import Api exposing (Shared)
import Browser
import Google.Rpc
import Html exposing (Html, button, code, div, form, h1, h2, input, label, li, p, pre, section, text, textarea, ul)
import Html.Attributes exposing (checked, class, name, placeholder, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Json.Encode
import Notes.V1 exposing (Note)
import Notes.V1.NotesService as Notes
import Proto.Any
import Rpc
import Rpc.ErrorCode
import Task


main : Program String Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = \_ -> Sub.none
        }


type alias Model =
    { shared : Shared
    , notes : List Note
    , newTitle : String
    , editing : Maybe Draft
    , sent : List Rpc.Request
    , failure : Maybe Rpc.Error
    }


{-| A note being edited, and the note as it was, to tell which fields changed.
-}
type alias Draft =
    { original : Note
    , title : String
    , body : String
    , tags : String
    }


init : String -> ( Model, Cmd Msg )
init origin =
    list
        { shared = { apiUrl = origin, token = "example-token", transport = Rpc.connect }
        , notes = []
        , newTitle = ""
        , editing = Nothing
        , sent = []
        , failure = Nothing
        }


type Msg
    = SetTransport Rpc.Transport
    | Listed (Result Rpc.Error Notes.V1.ListNotesResponse)
    | Changed (Result Rpc.Error ())
    | SetNewTitle String
    | Create
    | Edit Note
    | SetTitle String
    | SetBody String
    | SetTags String
    | Save
    | Cancel
    | Archive String
    | Delete String
    | GetMissing


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        -- region toggle
        SetTransport transport ->
            let
                shared =
                    model.shared
            in
            list { model | shared = { shared | transport = transport } }

        -- endregion toggle
        Listed (Ok response) ->
            ( { model | notes = response.notes }, Cmd.none )

        Listed (Err error) ->
            ( { model | failure = Just error }, Cmd.none )

        Changed (Ok ()) ->
            list { model | newTitle = "", editing = Nothing, failure = Nothing }

        Changed (Err error) ->
            ( { model | failure = Just error }, Cmd.none )

        SetNewTitle title ->
            ( { model | newTitle = title }, Cmd.none )

        Create ->
            let
                note =
                    Notes.V1.defaultNote
            in
            change model (Notes.createNote { note = Just { note | title = model.newTitle } })

        Edit note ->
            ( { model | editing = Just { original = note, title = note.title, body = note.body, tags = String.join ", " note.tags } }
            , Cmd.none
            )

        SetTitle title ->
            ( editDraft (\draft -> { draft | title = title }) model, Cmd.none )

        SetBody body ->
            ( editDraft (\draft -> { draft | body = body }) model, Cmd.none )

        SetTags tags ->
            ( editDraft (\draft -> { draft | tags = tags }) model, Cmd.none )

        Save ->
            case model.editing of
                Just draft ->
                    change model (Notes.updateNote (updateRequest draft))

                Nothing ->
                    ( model, Cmd.none )

        Cancel ->
            ( { model | editing = Nothing }, Cmd.none )

        Archive noteName ->
            change model (Notes.archiveNote { name = noteName })

        Delete noteName ->
            change model (Notes.deleteNote { name = noteName })

        GetMissing ->
            change model (Notes.getNote { name = "notes/missing" })


editDraft : (Draft -> Draft) -> Model -> Model
editDraft edit model =
    { model | editing = Maybe.map edit model.editing }



-- region first-call


list : Model -> ( Model, Cmd Msg )
list model =
    let
        call =
            Notes.listNotes Notes.V1.defaultListNotesRequest
    in
    ( record call model
    , Api.rpc model.shared call |> Task.attempt Listed
    )



-- endregion first-call


{-| Sends a call whose answer the page does not show, and lists the notes
again when it succeeds.
-}
change : Model -> Rpc.Call req res -> ( Model, Cmd Msg )
change model call =
    ( record call model
    , Api.rpc model.shared call
        |> Task.map (\_ -> ())
        |> Task.attempt Changed
    )


{-| Keeps the HTTP request a call becomes under the current config, to show it.
`Rpc.request` builds it without sending anything; `Api.rpc` sends the same.
-}
record : Rpc.Call req res -> Model -> Model
record call model =
    { model | sent = List.take 5 (Rpc.request (Api.config model.shared) call :: model.sent) }



-- region update-mask


updateRequest : Draft -> Notes.V1.UpdateNoteRequest
updateRequest draft =
    let
        note =
            draft.original

        tags =
            draft.tags
                |> String.split ","
                |> List.map String.trim
                |> List.filter (not << String.isEmpty)

        changed field isChanged =
            if isChanged then
                Just field

            else
                Nothing
    in
    { note = Just { note | title = draft.title, body = draft.body, tags = tags }
    , updateMask =
        Just
            (List.filterMap identity
                [ changed "title" (draft.title /= note.title)
                , changed "body" (draft.body /= note.body)
                , changed "tags" (tags /= note.tags)
                ]
            )
    }



-- endregion update-mask


view : Model -> Html Msg
view model =
    div []
        [ h1 [] [ text "Notes" ]
        , viewTransport model.shared.transport
        , Maybe.map viewError model.failure |> Maybe.withDefault (text "")
        , section []
            [ h2 [] [ text "Notes" ]
            , ul [] (List.map viewNote model.notes)
            , form [ onSubmit Create ]
                [ input [ placeholder "Title of a new note", value model.newTitle, onInput SetNewTitle ] []
                , button [] [ text "Create" ]
                ]
            , button [ onClick GetMissing ] [ text "Get notes/missing" ]
            ]
        , Maybe.map viewDraft model.editing |> Maybe.withDefault (text "")
        , section []
            [ h2 [] [ text "Sent, newest first" ]
            , div [] (List.map viewRequest model.sent)
            ]
        ]


viewTransport : Rpc.Transport -> Html Msg
viewTransport transport =
    let
        isConnect =
            case transport of
                Rpc.Connect _ ->
                    True

                Rpc.Transcode ->
                    False

        option label_ isChosen choice =
            label []
                [ input [ type_ "radio", name "transport", checked isChosen, onClick (SetTransport choice) ] []
                , text label_
                ]
    in
    p []
        [ text "Transport: "
        , option " Connect " isConnect Rpc.connect
        , option " HTTP transcoding" (not isConnect) Rpc.Transcode
        ]


viewNote : Note -> Html Msg
viewNote note =
    li []
        [ text (note.title ++ " ")
        , code [] [ text note.name ]
        , text (" " ++ String.join ", " note.tags ++ " ")
        , text (Maybe.map (\revision -> "(revision " ++ revision ++ ") ") note.revision |> Maybe.withDefault "")
        , button [ onClick (Edit note) ] [ text "Edit" ]
        , button [ onClick (Archive note.name) ] [ text "Archive" ]
        , button [ onClick (Delete note.name) ] [ text "Delete" ]
        ]


viewDraft : Draft -> Html Msg
viewDraft draft =
    section []
        [ h2 [] [ text ("Editing " ++ draft.original.name) ]
        , form [ onSubmit Save ]
            [ p [] [ input [ value draft.title, onInput SetTitle ] [] ]
            , p [] [ textarea [ value draft.body, onInput SetBody ] [] ]
            , p [] [ input [ value draft.tags, onInput SetTags, placeholder "tags, comma-separated" ] [] ]
            , button [] [ text "Save" ]
            , button [ type_ "button", onClick Cancel ] [ text "Cancel" ]
            ]
        ]


viewRequest : Rpc.Request -> Html msg
viewRequest request =
    pre [] [ text (request.method ++ " " ++ request.url ++ "\n" ++ Maybe.withDefault "" request.body) ]



-- region error


viewError : Rpc.Error -> Html msg
viewError error =
    case error of
        Rpc.Status status answer ->
            section [ class "error" ]
                [ h2 [] [ text (Rpc.ErrorCode.toString status.code) ]
                , p [] [ text status.message ]
                , p [] [ text ("Read from " ++ sourceToString status.source ++ " (HTTP " ++ String.fromInt answer.statusCode ++ ")") ]
                , ul []
                    (List.map
                        (\violation -> li [] [ code [] [ text violation.field ], text (": " ++ violation.description) ])
                        (Rpc.details Google.Rpc.messageBadRequest error |> List.concatMap .fieldViolations)
                    )
                , ul []
                    (List.map
                        (\info -> li [] [ text (info.reason ++ " from " ++ info.domain) ])
                        (Rpc.details Google.Rpc.messageErrorInfo error)
                    )
                , div [] (List.map viewDetail status.details)
                ]

        Rpc.Http answer ->
            section [ class "error" ]
                [ h2 [] [ text (Rpc.ErrorCode.toString (Rpc.code error)) ]
                , p [] [ text (Rpc.message error) ]
                , p [] [ text ("Inferred from the HTTP status " ++ String.fromInt answer.statusCode ++ "; the body was:") ]
                , pre [] [ text answer.body ]
                ]

        Rpc.Transport _ ->
            section [ class "error" ] [ p [] [ text (Rpc.errorToString error) ] ]


viewDetail : Proto.Any.Any -> Html msg
viewDetail detail =
    pre [] [ text (Json.Encode.encode 2 (Proto.Any.encodeJson detail)) ]


sourceToString : Rpc.Source -> String
sourceToString source =
    case source of
        Rpc.ConnectBody ->
            "a Connect error body"

        Rpc.StatusBody ->
            "a google.rpc.Status body"

        Rpc.GrpcHeaders ->
            "the grpc-status header"



-- endregion error
