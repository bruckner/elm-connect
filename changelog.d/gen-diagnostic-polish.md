- `input::not_proto3` for a file with no `syntax` statement says that
  the missing statement is what makes it proto2, and points at the
  file's first line rather than underlining the whole file.
- A misspelled option key in the plugin parameter (`int_64=int`) gets a
  did-you-mean (`int64`), as a misspelled rename does.
- `elm-connect` reports a requested file that declares
  `syntax = "proto2"`, or no syntax, and does not parse, as a proto3
  file whose `syntax` line was changed does not, as `input::not_proto3`
  alone, rather than as a parser error about labels for every field.
- A file or import the CLI finds on no include path is
  `input::file_not_found`, a new code, and its help names an `-I`
  directory that does not exist.
- `input::field_name_conflict` explains itself without naming the
  descriptor library, labels the two fields "this field" and "has the
  same name as this one once lowercased without underscores", and under
  the CLI is rendered with the header and the catalogue pointer the other
  diagnostics have.
- Generated doc comments put `an` before a type name that starts with
  a vowel sound ("An [`Author`]…", "Encodes an [`Event`]…"), where they
  always wrote `a`.
