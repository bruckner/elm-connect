- A 64-bit integer written as a JSON number reads as the exact value of
  the number JavaScript's JSON parser made of it. Before, a number past
  2^53 read as JavaScript writes it, which can end in zeros the value
  does not have: `9223372036854774784` read as `"9223372036854775000"`,
  and `-9223372036854775808` failed as out of range. A number no double
  holds is still rounded by the parser before the decoder sees it, and
  reads as the rounded value; written as a string, every digit is kept.
