- Building a Connect POST no longer percent-encodes the message for a
  GET URL it will not use, `Rpc.send` encodes the message a second time
  only to measure it against a `withWriteMaxBytes` limit, and a header
  value is checked in one pass: `Rpc.request` and `Rpc.send` are several
  times faster on POST calls (a 330-byte message about 7x, a 12 KB one
  about 16x). What is sent is unchanged.
