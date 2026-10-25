- A transcoded call whose path value cannot match its variable's
  template, an empty value or `notes/a/b` for `{name=notes/*}`, is no
  longer sent: it fails with the new
  `NoAnswer (InvalidPathValue { field, template })`, code
  `InvalidArgument`, naming the field. It used to go out as `GET /v1/`
  or `/v1/notes/a/b` and come back a 404, read as `Unimplemented`.
  `Rpc.request` still builds the URL. A `case` on `Rpc.Error.Reason`
  needs the new branch.
