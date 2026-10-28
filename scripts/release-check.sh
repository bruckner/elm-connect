#!/usr/bin/env bash
# Hold the commits of a range to the release discipline (design §8.7):
# only an `Open <version>` or `Reopen as <version>` commit changes the
# version lines, and leaves them in agreement; a `Cut <version>` commit
# changes the changelog alone and adds the version's section to it.
#
#   scripts/release-check.sh [<base>..<head> | <commit>]
#
# A single commit is checked alone, and HEAD with no argument. Merge
# commits are skipped: what they bring in is checked as the commits it
# consists of.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

range=${1:-HEAD}
case $range in *..*) ;; *) range="$range^!" ;; esac
version_re='[0-9]+\.[0-9]+\.[0-9]+'
status=0

fail() {
    local commit=$1 subject=$2 message=$3
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        printf '::error::%s "%s": %s\n' "$commit" "$subject" "$message" >&2
    else
        printf 'release-check: %s "%s": %s\n' "$commit" "$subject" "$message" >&2
    fi
    status=1
}

# The added and removed lines of one file in one commit, without the
# file headers.
changed_lines() {
    git show --no-ext-diff --format= --unified=0 "$1" -- "$2" | grep -E '^[-+]' | grep -vE '^(---|\+\+\+) ' || true
}

# The version lines one commit changes, as the names of their files.
version_lines() {
    local commit=$1
    if changed_lines "$commit" Cargo.toml | grep -qE '^[-+](version = |elm-connect-gen = \{.*version = )'; then
        echo "Cargo.toml"
    fi
    if changed_lines "$commit" elm.json | grep -qE '^[-+][[:space:]]*"version":'; then
        echo "elm.json"
    fi
    if [ -n "$(changed_lines "$commit" src/Proto/Version.elm)" ]; then
        echo "src/Proto/Version.elm"
    fi
}

# Whether the version lines at one commit all name one version: the
# workspace's, the generator dependency's, elm.json's, and the
# `Proto.Version` value of its minor.
check_agreement() {
    local commit=$1 subject=$2 version=$3
    local cargo dependency elm sentinel
    cargo=$(git show "$commit:Cargo.toml" | sed -n '/^\[workspace\.package\]/,/^\[/s/^version = "\(.*\)"$/\1/p')
    dependency=$(git show "$commit:Cargo.toml" | sed -n 's/^elm-connect-gen = {.*version = "\([^"]*\)".*/\1/p')
    elm=$(git show "$commit:elm.json" | sed -n 's/^    "version": "\(.*\)",*$/\1/p')
    sentinel="v$(echo "$version" | cut -d. -f1)_$(echo "$version" | cut -d. -f2)"
    if [ "$cargo" != "$version" ] || [ "$dependency" != "$version" ] || [ "$elm" != "$version" ]; then
        fail "$commit" "$subject" "the version lines disagree with $version: Cargo.toml's workspace version is \"$cargo\", its elm-connect-gen dependency \"$dependency\", elm.json's version \"$elm\"; an Open commit sets them all (just release-open $version)"
    fi
    if ! git show "$commit:src/Proto/Version.elm" |
        sed -n 's/^module Proto\.Version exposing (\(.*\))$/\1/p' | tr ',' '\n' | tr -d ' ' | grep -qx "$sentinel"; then
        fail "$commit" "$subject" "src/Proto/Version.elm does not expose $sentinel, the value $version's generated code names (design §8.2)"
    fi
}

check_cut() {
    local commit=$1 subject=$2 version=$3
    local others cargo
    others=$(git show --format= --name-only "$commit" | grep -vE '^(CHANGELOG\.md|changelog\.d/.*)$' || true)
    if [ -n "$others" ]; then
        fail "$commit" "$subject" "a Cut commit changes CHANGELOG.md and changelog.d/ only, and this one also changes: $(echo "$others" | tr '\n' ' ' | sed 's/ $//')"
    fi
    if ! changed_lines "$commit" CHANGELOG.md | grep -qF "+## $version — "; then
        fail "$commit" "$subject" "a Cut commit adds CHANGELOG.md's \"## $version — <date>\" section (just release-cut $version), and this one does not"
    fi
    cargo=$(git show "$commit:Cargo.toml" | sed -n '/^\[workspace\.package\]/,/^\[/s/^version = "\(.*\)"$/\1/p')
    if [ "$cargo" != "$version" ]; then
        fail "$commit" "$subject" "cuts $version, but the workspace's version is \"$cargo\"; the Open commit sets the version the Cut releases"
    fi
}

commits=$(git rev-list --reverse --no-merges "$range")
for commit in $commits; do
    short=$(git rev-parse --short "$commit")
    subject=$(git log -1 --format=%s "$commit")
    if [[ $subject =~ ^(Open|Reopen\ as)\ ($version_re)$ ]]; then
        check_agreement "$short" "$subject" "${BASH_REMATCH[2]}"
        continue
    fi
    if [[ $subject =~ ^Cut\ ($version_re)$ ]]; then
        check_cut "$short" "$subject" "${BASH_REMATCH[1]}"
        continue
    fi
    files=$(version_lines "$commit")
    if [ -n "$files" ]; then
        fail "$short" "$subject" "changes the release's version ($(echo "$files" | tr '\n' ' ' | sed 's/ $//')), which only a commit named \"Open <version>\" or \"Reopen as <version>\" may do (design §8.7); leave the version lines as main has them"
    fi
done

exit $status
