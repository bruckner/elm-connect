- `Proto.Binary` fails to decode a `string` field cut off in the
  middle of a character (its last byte the start of a multi-byte
  character, or a stray continuation byte). Before, the string was read
  past the field's end and the fields after it read out of place; when
  the bytes past the message were there to read, as behind an `Any`'s
  value or a gRPC-Web frame, the decode could succeed with wrong
  contents.
