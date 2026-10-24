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
- `Rpc.Retry.next` gives a policy's schedule as a pure function: after a
  failed attempt, the wait before the next one, or `Nothing` to stop,
  exactly as the runtime's own loop decides it. An application that runs
  the retry loop itself, to show that it is waiting, to let the user
  cancel or to refresh something between attempts, sends each attempt
  with `Rpc.Call.withoutRetry` and takes the waits, cap, attempt limit,
  jitter and deadline from it. docs/calling.md shows such a loop.
