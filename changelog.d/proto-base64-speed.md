- `Proto.Bytes.fromBase64` and `toBase64` are faster: about two times
  for reading and two and a half times for writing a kilobyte, more on
  larger values. Every `Any`, and every `bytes` field held as `Bytes`,
  goes through them; unpacking or packing an `Any` of about 800 bytes
  takes about half as long. They accept and write the same text as
  before, and `toBase64` returns it as one flat string, so text held in
  a model costs about a byte per character.
