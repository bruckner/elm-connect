- A transcoded call whose path value cannot match its variable's
  template, an empty value or `notes/a/b` for `{name=notes/*}`, is no
  longer sent: it fails as a `BadCall`, code `InvalidArgument`, naming
  the field and the template. It used to go out as `GET /v1/`
  or `/v1/notes/a/b` and come back a 404, read as `Unimplemented`.
  `Rpc.request` still builds the URL.
