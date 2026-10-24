- `input::not_proto3` for a file with no `syntax` statement says that
  the missing statement is what makes it proto2, and points at the
  file's first line rather than underlining the whole file.
- A misspelled option key in the plugin parameter (`int_64=int`) gets a
  did-you-mean (`int64`), as a misspelled rename does.
