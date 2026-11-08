- `Proto.Bytes.fromBase64` and `toBase64` are faster: about two times
  for reading and three times for writing a kilobyte, more on larger
  values. Every `Any`, and every `bytes` field held as `Bytes`, goes
  through them; unpacking or packing an `Any` of about 800 bytes takes
  about half as long. They accept and write the same text as before.
