- Reading a proto3 JSON `Any` through a lenient registry reads each
  `Any` nested in it at most twice, where it read them a number of
  times growing with the square of the depth when a type inside was
  one the registry lacks: a 100-deep chain with 300 KB in it now reads
  in about a fifth of the time. What is read, and every failure, is
  unchanged.
