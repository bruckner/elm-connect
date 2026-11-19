- Fixed: `==` on two protocols, or two clients, that differ in a
  modifier answers `False` under Elm 0.19.3, where it threw ("Trying to
  use `(==)` on functions"): the runtime no longer depends on the order
  the compiler writes a record's fields in. Two clients that differ in
  their retry policy or timeout, each with a registry built in place,
  now compare unequal too, where they threw under every Elm release;
  two otherwise alike with such registries still throw.
