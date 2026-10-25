- Text holding a lone low surrogate (U+DC00 to U+DFFF without the high
  half before it) no longer hangs the runtime. At the start of a
  transcoded call's path or query value, a timestamp's fraction, base64
  text or a field mask path read from JSON, it made the read loop until
  the page ran out of memory; elsewhere it was misread together with
  the character before it. A path value holding a surrogate without its
  pair is now refused with `NoAnswer (InvalidPathValue { field,
  template })`, nothing sent (a lone high surrogate was sent as U+FFFD);
  a query value writes each as U+FFFD; base64 text, timestamps and
  64-bit integers holding one are rejected (`Proto.Int64.toInt "1\u{DC00}2"`
  was `Just 562822`).
