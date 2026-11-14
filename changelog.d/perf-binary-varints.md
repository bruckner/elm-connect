- Writing protobuf binary is faster: by 17 % for a single message, 13 %
  for a list of 300, 30 % for a 16-field message, more than half for
  packed `int32` fields, and 15 % for building a binary request, with
  varints written as 16- and 32-bit words. A packed run of doubles is
  written about 17 to 19 % slower. The bytes written are the same.
- Reading protobuf binary is faster again: by 10 to 20 % for single,
  listed, nested, map-heavy and 16-field messages and packed `int32`
  fields, and 10 % for a 1 KB answer over Connect's proto codec, with
  varints read by a fixed chain and one-byte keys, `int32`s, enums and
  `bool`s read in one step.
