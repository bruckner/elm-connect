- Fixed: a send encodes its JSON request once. A method built with
  `Proto.Method.init` encoded it twice, once for the body and once to
  check it for an unregistered type, and a method with
  `Proto.Method.withBindings` twice over transcoding, once for its route
  and once more for the check or the write limit; reading an answer with
  `Rpc.response` over such a route encoded it too, and now encodes
  nothing. A route read from bindings as data now writes an `Any` with the
  client's registry (`Rpc.withRegistry`), as the body over Connect does,
  where it used the method's own.
