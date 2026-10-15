#!/usr/bin/env bash
# Check that the code blocks of the given Markdown files are excerpts of files
# in this repository, so the documents cannot drift from code that compiles.
#
# A block is tagged in its fence's info string, after the language:
#
#   ```elm examples/notes/elm/src/Api.elm#wrapper
#       the lines between `region wrapper` and `endregion wrapper` comments
#       (`--`, `//` or `#`) in that file, blank lines at either end dropped
#   ```json examples/notes/elm/elm.json
#       consecutive lines of that file
#   ```elm examples/notes/elm/generated/Notes/V1/NotesService.elm excerpt
#       lines of that file in order, others between them left out (for
#       generated files, which carry no region comments)
#
# Except in an excerpt, either side's common indentation is removed before
# comparing. Every `elm`
# and `proto` block must be tagged; other blocks may be. Paths are from the
# repository root. Usage: examples/check-snippets.sh FILE.md...
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Lines without their common indentation and without blank lines at either end.
normalize() {
  awk '
    { line[NR] = $0
      if ($0 ~ /[^ ]/) {
        match($0, /^ */)
        if (min == "" || RLENGTH < min) min = RLENGTH
        if (first == "") first = NR
        last = NR
      } }
    END { for (i = first; i <= last && first != ""; i++) print substr(line[i], min + 1) }
  '
}

failures=0
checked=0
for doc in "$@"; do
  # Split the document into its fenced blocks: block N's info string in
  # N.info, its lines in N.body, its line number in N.line.
  rm -f "$work"/*.info "$work"/*.body "$work"/*.line
  awk -v dir="$work" '
    /^```/ {
      if (open) { open = 0; next }
      open = 1; n++
      print substr($0, 4) > (dir "/" n ".info")
      print NR > (dir "/" n ".line")
      printf "" > (dir "/" n ".body")
      next
    }
    open { print > (dir "/" n ".body") }
  ' "$doc"

  for info_file in "$work"/*.info; do
    [[ -e "$info_file" ]] || continue
    n="$(basename "$info_file" .info)"
    read -r lang tag mode <"$info_file" || true
    where="$doc:$(cat "$work/$n.line")"
    if [[ -z "${tag:-}" ]]; then
      if [[ "$lang" == elm || "$lang" == proto ]]; then
        echo "$where: an untagged $lang block" >&2
        failures=$((failures + 1))
      fi
      continue
    fi
    path="${tag%%#*}"
    if [[ ! -f "$root/$path" ]]; then
      echo "$where: no file $path" >&2
      failures=$((failures + 1))
      continue
    fi
    normalize <"$work/$n.body" >"$work/block"
    awk '/[^ ]/ { if (!started) started = 1 } started' "$work/$n.body" >"$work/raw"
    checked=$((checked + 1))
    if [[ "$tag" == *"#"* ]]; then
      region="${tag#*#}"
      awk -v name="$region" '
        $0 ~ "^ *(--|//|#) *endregion " name " *$" { inside = 0; found = 1 }
        inside { print }
        $0 ~ "^ *(--|//|#) *region " name " *$" { inside = 1 }
        END { if (!found) exit 1 }
      ' "$root/$path" | normalize >"$work/expected" || {
        echo "$where: no region $region in $path" >&2
        failures=$((failures + 1))
        continue
      }
      if ! diff -u -L "$path#$region" -L "$doc" "$work/expected" "$work/block" >"$work/diff"; then
        echo "$where: the block differs from region $region of $path:" >&2
        sed 's/^/  /' "$work/diff" >&2
        failures=$((failures + 1))
      fi
    elif [[ "${mode:-}" == excerpt ]]; then
      # Each non-blank line of the block, in order, as a line of the file.
      if ! awk '
        FNR == NR { if ($0 ~ /[^ ]/) want[++wanted] = $0; next }
        next_line <= wanted && $0 == want[next_line + 0] { next_line++ }
        BEGIN { next_line = 1 }
        END { if (next_line <= wanted) { print want[next_line]; exit 1 } }
      ' "$work/raw" "$root/$path" >"$work/missing"; then
        echo "$where: not an excerpt of $path; from this line on: $(cat "$work/missing")" >&2
        failures=$((failures + 1))
      fi
    else
      # The block as consecutive lines of the file, each window of the file
      # without its own common indentation.
      if ! awk '
        FNR == NR { want[++wanted] = $0; next }
        { line[++lines] = $0 }
        END {
          for (start = 1; start + wanted - 1 <= lines; start++) {
            min = -1
            for (i = 0; i < wanted; i++) {
              if (line[start + i] ~ /[^ ]/) {
                match(line[start + i], /^ */)
                if (min < 0 || RLENGTH < min) min = RLENGTH
              }
            }
            for (i = 1; i <= wanted; i++) {
              got = line[start + i - 1]
              if (got ~ /[^ ]/) got = substr(got, min + 1)
              if (got != want[i]) break
            }
            if (i > wanted) exit 0
          }
          exit 1
        }
      ' "$work/block" "$root/$path"; then
        echo "$where: not consecutive lines of $path" >&2
        failures=$((failures + 1))
      fi
    fi
  done
done

if ((failures > 0)); then
  echo "check-snippets: $failures of the tagged blocks failed" >&2
  exit 1
fi
echo "check-snippets: $checked blocks match their files"
