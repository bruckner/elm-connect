- Breaking: a `google.protobuf.Timestamp` is `Proto.Timestamp.Timestamp`,
  an opaque type exact to the nanosecond, where it was a `Time.Posix`,
  which dropped every digit past the millisecond. Generated fields are
  `Maybe Proto.Timestamp.Timestamp` (bare in a list, map or oneof),
  written qualified, and generated modules no longer import `Time`
  (regenerate). `Proto.Json.Decode.timestamp`, `Proto.Json.Encode.timestamp`,
  `Proto.Binary.timestamp` and `Proto.WellKnown.timestamp` take the new
  type. The protobuf
  conformance suite's fourteen sub-millisecond `Timestamp` cases now
  pass.
- `Proto.Timestamp.fromPosix` (exact, clamping outside years 1 to 9999),
  `toPosix` (normalised, clamped, truncated toward the past), `now`,
  `fromSecondsAndNanos` (normalised, `Nothing` outside the range),
  `toSecondsAndNanos` (the fields as held), `isValid` and `normalize`
  (not clamped).
- Breaking: `Proto.Timestamp.toString` gives a `Maybe String`, `Nothing`
  for a timestamp that is not valid, and prints 0, 3, 6 or 9 fractional
  digits; `fromString` keeps every digit of the fraction.
- Breaking: a `Timestamp` read from protobuf binary is held as the peer
  wrote it, neither normalised nor clamped, and written back to binary
  as held. A proto3 JSON write refuses one that is not valid (outside
  years 1 to 9999, or its nanoseconds outside 0 to 999,999,999) with
  `Proto.Error.BadValue`. Seconds outside ±(2^53 − 1), which an `Int`
  does not hold exactly, no longer fail the read: they are held exactly
  and written back as read, and `toSecondsAndNanos` gives the nearest
  `Int`.
- A generated route prints a timestamp in a path or query with
  `Proto.Timestamp.toString`, as before; one that is not valid has no
  text, and the route has what it has for an unset one. A request over
  JSON holding one is refused before its route is built.
