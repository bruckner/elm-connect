- Breaking: `Proto.Duration.fromMilliseconds` and `toMilliseconds` are
  `fromMillis` and `toMillis`; `fromParts` and `toParts` are
  `fromSecondsAndNanos` and `toSecondsAndNanos`.
- Breaking: `Proto.Duration.toString` gives a `Maybe String`, `Nothing`
  for a duration that is not valid, which only one read from protobuf
  binary can be.
- Breaking: `Proto.Duration.fromSecondsAndNanos` gives a `Maybe`,
  `Nothing` past protobuf's range, where `fromParts` clamped.
  `fromSeconds` and `fromMillis` still clamp.
- Breaking: a `Duration` read from protobuf binary is held as the peer
  wrote it, neither normalised nor clamped, and written back to binary
  as held; one arriving twice is merged field by field and not given
  one sign. A proto3 JSON write refuses one that is not valid (past
  protobuf's range, or its nanoseconds of a second or more or of the
  other sign than its seconds) with `Proto.Error.BadValue`.
- `Proto.Duration.isValid` and `normalize`: protobuf's validity rule
  and the normal form (not clamped).
- A generated route prints a duration in a path or query with
  `Proto.Duration.toString`; one that is not valid has no text, and the
  route has what it has for an unset one. A request over JSON holding
  one is refused before its route is built.
- Breaking: generated code writes `Proto.Duration.Duration` qualified
  and imports no runtime module exposing a name (regenerate), so a
  message named `Duration` no longer needs a `rename`. The protobuf
  conformance suite's two out-of-range `Duration` cases now pass.
