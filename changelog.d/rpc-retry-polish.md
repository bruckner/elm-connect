- `Rpc.Call.withRetry` gives one call its own retry policy in place of
  the config's `retry`, as `Rpc.Call.withTimeout` does the timeout.
- `Rpc.Call.withoutRetry` sends a call once whatever the config's
  `retry` says. Sent so through `Rpc.send`, the call keeps its tracker,
  so `Rpc.cancel` can stop it under a config that retries; until now
  such a call needed a config of its own with `retry = Nothing`.
- `Rpc.Retry.withDeadline ms` bounds all of a call's attempts and the
  waits between them together. No wait begins that would end past the
  deadline, and each attempt's timeout, `Connect-Timeout-Ms` included,
  is cut to what is left of it. Without one, as before, the timeout
  applies to each attempt alone.
