- A generated call over JSON whose request holds nothing a JSON write can
  refuse is no longer written to check it before a typed route is built:
  a transcoded `GET` of such a request writes no JSON, and its
  `body: "*"` route writes the body once.
- New `Proto.Method.withoutRequestCheck : Method codec req res -> Method
  codec req res`: a send over one of the method's typed routes, under no
  write limit, does not write the request's JSON only to check it.
  Wherever the JSON is written anyway (Connect, the implicit route, a
  route that takes the JSON, a write limit) a refusal is still reported.
  Nothing verifies the flag; generated code sets it where the request
  holds nothing a JSON write can refuse.
