- Fixed: a client whose calls speak JSON alone no longer carries
  elm/bytes when its protocol is given `withConnectGet` or
  `withWriteMaxBytes`: such a program is about 760 B smaller gzipped
  (both modifiers pulled in elm/bytes' kernel for the binary protocols' use).
