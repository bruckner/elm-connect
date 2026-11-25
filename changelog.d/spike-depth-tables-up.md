- A recursive message's JSON decoders for each depth are made from the
  deepest up, each given the next directly, so a recursive read no longer
  looks the next level up as it goes. The messages of a cycle of several
  make theirs together, in one generated value named for the cycle's first
  message (`cyclePerson`), which `decodeNestedPerson` reads.
  `Proto.Json.memo` takes the next level and the decoders past the limit,
  and `Proto.Json` gains `tooDeep`.
