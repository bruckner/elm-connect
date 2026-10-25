- Every generated module's second line records the options it was
  generated with, as the plugin parameter writes them, those at their
  defaults left out: `-- Options: int64=int, module_prefix=Api`, or
  `-- Options: defaults`.
- `elm-connect check` says which of three things it found: modules
  generated with other options than it was given, naming each option
  that differs and printing the `gen` command that regenerates them
  with the options on disk; modules from another release; or modules
  out of date, with their diffs. Before, a check given other options
  printed every module's diff as out of date.
