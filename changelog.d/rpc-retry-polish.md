- `Rpc.Call.withRetry` gives one call its own retry policy in place of
  the config's `retry`, as `Rpc.Call.withTimeout` does the timeout.
- `Rpc.Call.withoutRetry` sends a call once whatever the config's
  `retry` says. Sent so through `Rpc.send`, the call keeps its tracker,
  so `Rpc.cancel` can stop it under a config that retries; until now
  such a call needed a config of its own with `retry = Nothing`.
