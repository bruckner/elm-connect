module Snippets.UpdateMaskTest exposing (suite)

import Dict
import Expect
import Notes.V1 exposing (Note, NoteKind(..))
import Proto.Duration
import Snippets.UpdateMask exposing (updateMask, validMask)
import Test exposing (Test, describe, test)
import Time


note : Note
note =
    { defaultNote
        | name = "notes/1"
        , title = "groceries"
        , tags = [ "home" ]
        , createTime = Just (Time.millisToPosix 1000)
        , metadata = Dict.fromList [ ( "color", "green" ) ]
        , kind = NoteKindText "milk"
    }


defaultNote : Note
defaultNote =
    Notes.V1.defaultNote


{-| The mask of an `UpdateNoteRequest` whose note changes from `before` to
`after`.
-}
noteMask : Note -> Note -> List String
noteMask before after =
    updateMask Notes.V1.registry
        Notes.V1.messageUpdateNoteRequest
        { note = Just before, updateMask = Nothing }
        { note = Just after, updateMask = Nothing }


suite : Test
suite =
    describe "update masks"
        [ test "nothing changed is an empty mask" <|
            \_ ->
                noteMask note note
                    |> Expect.equal []
        , test "a nested message's changed fields are named through it, by proto name" <|
            \_ ->
                noteMask note { note | title = "errands", ttl = Just (Proto.Duration.fromMilliseconds 60000) }
                    |> Expect.equal [ "note.title", "note.ttl" ]
        , test "a field set back to its default is in the mask" <|
            \_ ->
                noteMask note { note | title = "" }
                    |> Expect.equal [ "note.title" ]
        , test "a well-known type is a leaf" <|
            \_ ->
                noteMask note { note | createTime = Just (Time.millisToPosix 2000) }
                    |> Expect.equal [ "note.create_time" ]
        , test "a repeated field and a map are named whole" <|
            \_ ->
                noteMask note { note | tags = [ "home", "work" ], metadata = Dict.insert "size" "large" note.metadata }
                    |> Expect.equal [ "note.tags", "note.metadata" ]
        , test "switching a oneof names the member cleared and the member set" <|
            \_ ->
                noteMask note { note | kind = NoteKindLink "https://example.com" }
                    |> Expect.equal [ "note.text", "note.link" ]
        , test "a message set on one side only is named whole" <|
            \_ ->
                updateMask Notes.V1.registry
                    Notes.V1.messageUpdateNoteRequest
                    { note = Nothing, updateMask = Nothing }
                    { note = Just note, updateMask = Nothing }
                    |> Expect.equal [ "note" ]
        , test "a mask's paths are checked against the descriptors" <|
            \_ ->
                [ [ "note.title", "note.create_time", "update_mask" ]
                , [ "note.text" ]
                , [ "note.titel" ]
                , [ "note.create_time.seconds" ]
                , [ "note.tags.x" ]
                , [ "note." ]
                , [ "" ]
                ]
                    |> List.map (validMask Notes.V1.registry Notes.V1.descriptorUpdateNoteRequest)
                    |> Expect.equal [ True, True, False, False, False, False, False ]
        ]
