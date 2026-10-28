#!/usr/bin/env bash
# Open a release cycle (design §8.7): set the version lines to the next
# release's, the Cargo workspace's version and its elm-connect-gen
# dependency, elm.json's version and Cargo.lock's entries for the three
# crates, and for a minor or major add its `Proto.Version` value (§8.2).
# Commits nothing; prints what the maintainer runs next.
#
#   scripts/release-open.sh <major>.<minor>.<patch>
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

die() {
    echo "release-open: $*" >&2
    exit 1
}

version=${1:-}
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    die "usage: just release-open <major>.<minor>.<patch>, without a v or a suffix (got \"$version\")"
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}

module=src/Proto/Version.elm
files=(Cargo.toml Cargo.lock elm.json "$module")
git diff --quiet HEAD -- "${files[@]}" ||
    die "${files[*]} have uncommitted changes; commit or discard them first"

current=$(sed -n '/^\[workspace\.package\]/,/^\[/s/^version = "\(.*\)"$/\1/p' Cargo.toml)
elm_current=$(sed -n 's/^    "version": "\(.*\)",*$/\1/p' elm.json)
[ "$current" = "$elm_current" ] ||
    die "Cargo.toml's version ($current) and elm.json's ($elm_current) disagree; the lockstep test says how they must stand"

# The version must move forward.
IFS=. read -r cur_major cur_minor cur_patch <<< "$current"
if [ "$major" -lt "$cur_major" ] ||
    { [ "$major" -eq "$cur_major" ] && [ "$minor" -lt "$cur_minor" ]; } ||
    { [ "$major" -eq "$cur_major" ] && [ "$minor" -eq "$cur_minor" ] && [ "$patch" -le "$cur_patch" ]; }; then
    die "$version does not follow the current version, $current"
fi

# Whether the current version was released decides between Open and
# Reopen, and whether its value is kept, so the tags must be here.
[ -n "$(git tag -l '[0-9]*.[0-9]*.[0-9]*')" ] ||
    die "no release tags in this clone; fetch them first (git fetch --tags)"
if git rev-parse -q --verify "refs/tags/$current" > /dev/null; then
    subject="Open $version"
    current_released=true
else
    subject="Reopen as $version"
    current_released=false
fi

exposed=$(sed -n 's/^module Proto\.Version exposing (\(.*\))$/\1/p' "$module" | tr ',' '\n' | tr -d ' ' | grep -E '^v[0-9]+_[0-9]+$' || true)
[ -n "$exposed" ] || die "$module exposes no v<major>_<minor> value"
latest=$(echo "$exposed" | tail -n 1)
value="v${major}_${minor}"

if [ "$patch" -eq 0 ]; then
    if echo "$exposed" | grep -qx "$value"; then
        die "$module already exposes $value; a .0 release is a new minor or major, whose value is new"
    fi
    # Before 1.0 a minor may change the shape of generated code, so the
    # module names the current minor alone; a major removes every value of
    # the last. Within a major from 1.0 on, every released minor's value is
    # kept, and a reopened cycle's own unreleased value is withdrawn.
    keep=
    if [ "$major" -ne 0 ] && [ "$minor" -ne 0 ]; then
        withdrawn=
        if [ "$current_released" = false ] && [ "$cur_patch" -eq 0 ]; then
            withdrawn="v${cur_major}_${cur_minor}"
        fi
        keep=$(echo "$exposed" | grep -E "^v${major}_" | grep -vx "${withdrawn:-none}" || true)
    fi
    values=$(printf '%s\n%s\n' "$keep" "$value" | grep -v '^$')
else
    echo "$exposed" | grep -qx "$value" ||
        die "$module does not expose $value; a patch release is of a minor whose value exists"
    values=$exposed
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Cargo.toml: the workspace's version and the generator dependency's.
sed -e '/^\[workspace\.package\]/,/^\[/s/^version = ".*"$/version = "'"$version"'"/' \
    -e 's/^\(elm-connect-gen = {.*version = "\)[^"]*"/\1'"$version"'"/' \
    Cargo.toml > "$tmp/Cargo.toml"
mv "$tmp/Cargo.toml" Cargo.toml

# elm.json: the package's version, the one field at that indentation.
sed 's/^\(    "version": "\)[^"]*"/\1'"$version"'"/' elm.json > "$tmp/elm.json"
mv "$tmp/elm.json" elm.json

# Cargo.lock: the workspace crates' entries, as `cargo update --workspace`
# would set them, without a registry.
awk -v version="$version" '
    /^\[\[package\]\]$/ { ours = 0 }
    /^name = "(elm-connect|elm-connect-gen|protoc-gen-elm-connect)"$/ { ours = 1 }
    ours && /^version = / { $0 = "version = \"" version "\""; ours = 0 }
    { print }
' Cargo.lock > "$tmp/Cargo.lock"
mv "$tmp/Cargo.lock" Cargo.lock

if [ "$patch" -eq 0 ]; then
    list=$(echo "$values" | tr '\n' ',' | sed -e 's/,$//' -e 's/,/, /g')
    # Each value's definition, from its doc comment to its body, is kept
    # as written; a new one gets the module's one-line doc. The module's
    # documentation names the newest value, and the release it stands for.
    awk -v dir="$tmp" '
        /^\{-\| elm-connect [0-9]/ { inside = 1; seen = 1; block = "" }
        !seen { print > (dir "/head"); next }
        !inside { next }
        { block = block $0 "\n" }
        /^v[0-9]+_[0-9]+ :/ { name = $1 }
        /^    Generated$/ { printf "%s", block > (dir "/" name); close(dir "/" name); inside = 0 }
    ' "$module"
    sed -e "s/$latest\\([^[:alnum:]_]\\)/$value\\1/g" \
        -e "s/$latest\$/$value/" \
        -e "s/\`$value\` is [0-9]*\\.[0-9]*\\.x/\`$value\` is $major.$minor.x/" \
        -e "s/^module Proto\\.Version exposing (.*)\$/module Proto.Version exposing (Generated, $list)/" \
        -e "s/^@docs Generated.*\$/@docs Generated, $list/" \
        "$tmp/head" > "$tmp/module"
    first=true
    for v in $values; do
        if [ "$first" = true ]; then first=false; else printf '\n\n' >> "$tmp/module"; fi
        if [ -f "$tmp/$v" ]; then
            cat "$tmp/$v" >> "$tmp/module"
        else
            n=${v#v}
            printf '{-| elm-connect %s.%s.\n-}\n%s : Generated\n%s =\n    Generated\n' "${n%_*}" "${n#*_}" "$v" "$v" >> "$tmp/module"
        fi
    done
    mv "$tmp/module" "$module"
fi

echo "Opened $version ($subject):"
git diff --stat -- "${files[@]}"
cat <<STEPS

Next, by hand, then commit everything as "$subject":
STEPS
if [ "$patch" -eq 0 ]; then
    cat <<STEPS
  - Read $module's module documentation: its prose may still describe
    $current.
  - git grep -n -e '$latest' -e '$cur_major\.$cur_minor\.X' -- ':!conformance/cases'
    finds the docs and comments that name the previous sentinel or the
    corpus's header placeholder.
  - just bless, and review the corpus diff: the sentinel and the header
    placeholder change in every expected module.
STEPS
fi
cat <<STEPS
  - just live-gen, just live-conformance-gen, just eliza-gen and
    just protobuf-conformance-gen regenerate the committed Elm, whose
    headers carry the version.
  - just check.
STEPS
