module ReviewConfig exposing (config)

{-| The unused-code review `just elm-review` runs over the runtime package and
its tests (`src/` and `tests/`).

`NoUnused.Exports` is left at its defaults: the exposed modules' exports are
the package's API and are not reported, and an `Internal` module's export that
only a test uses counts as used, which keeps the seams the tests hold. What it
reports is an export nothing outside its module uses.

`tests/Generated/` is written by recipes; the rules never report on it, though
what it imports still counts as used.

-}

import NoUnused.CustomTypeConstructorArgs
import NoUnused.CustomTypeConstructors
import NoUnused.Dependencies
import NoUnused.Exports
import NoUnused.Parameters
import NoUnused.Patterns
import NoUnused.Variables
import Review.Rule as Rule exposing (Rule)


config : List Rule
config =
    List.map (Rule.ignoreErrorsForDirectories [ "tests/Generated/" ])
        [ -- These test values are compared structurally (`Json`, `EventKind`),
          -- so their arguments are read by `==`, which the rule cannot see; the
          -- `Msg` of RpcTest is the message type a command is checked against.
          NoUnused.CustomTypeConstructorArgs.rule
            |> Rule.ignoreErrorsForFiles
                [ "tests/Codec/RoundTrip.elm"
                , "tests/Proto/JsonTest.elm"
                , "tests/RpcTest.elm"
                ]
        , NoUnused.CustomTypeConstructors.rule []
            |> Rule.ignoreErrorsForFiles [ "tests/RpcTest.elm" ]
        , NoUnused.Dependencies.rule
        , NoUnused.Exports.rule
        , NoUnused.Parameters.rule
        , NoUnused.Patterns.rule
        , NoUnused.Variables.rule
        ]
