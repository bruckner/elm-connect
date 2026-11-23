- The generator warns, as `types::deep_nesting`, when generated
  messages hold each other in a chain of more than 100 without a cycle
  (`A1` holding `A2` … holding `A101`): reads count the nesting of
  messages on a cycle alone, so such a chain is read to its end, while
  most protobuf runtimes refuse a message nested more than 100 deep.
  The warning names the longest chain's outermost message, its length
  and its first and last messages; generation still succeeds.
