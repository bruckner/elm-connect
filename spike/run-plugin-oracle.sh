#!/usr/bin/env bash
# Drives the plugin with protoc (PROTOC, a protoc binary) and with buf (pinned
# by mise.toml) over the corpus's editions cases and codec_both, the proto3
# case the first of them twins, and compares what each writes with what the
# CLI writes for the same protos and options, and with the case's expected
# modules (their version placeholder put back). Diagnostics cases are run
# through both and their problem codes listed. Writes into OUT, a scratch
# directory. Usage: spike/run-plugin-oracle.sh OUT
set -euo pipefail
out=$(mkdir -p "$1" && cd "$1" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
protoc=${PROTOC:?set PROTOC to a protoc binary}
cli=$root/target/debug/elm-connect
plugin=$root/target/debug/protoc-gen-elm-connect
version=$("$cli" --version | awk '{print $2}')
placeholder="${version%.*}.X"

"$protoc" --version
mise exec -C "$root" -- buf --version
mise exec -C "$root" -- cargo build -q -j4 -p elm-connect -p protoc-gen-elm-connect

rc=0
for case_dir in "$root"/conformance/cases/editions_* "$root/conformance/cases/codec_both"; do
    case=$(basename "$case_dir")
    input=$case_dir/input
    files=$(cd "$input" && find . -name '*.proto' | sed 's|^\./||' | sort)
    parameter=$(cat "$case_dir/options.txt" 2>/dev/null || true)
    flags=()
    IFS=',' read -r -a pairs <<< "$parameter"
    for pair in "${pairs[@]:-}"; do
        [[ -n $pair ]] && flags+=("--${pair%%=*}" "${pair#*=}")
    done
    flags=("${flags[@]//_/-}")
    rm -rf "$out/$case" && mkdir -p "$out/$case"/{cli,protoc,buf,expected}
    # shellcheck disable=SC2086
    "$cli" gen -I "$input" $files ${flags[@]+"${flags[@]}"} --out "$out/$case/cli" \
        > /dev/null 2> "$out/$case/cli.err" || true
    # shellcheck disable=SC2086
    (cd "$input" && "$protoc" -I . --plugin=protoc-gen-elm-connect="$plugin" \
        --elm-connect_out="$out/$case/protoc" ${parameter:+--elm-connect_opt="$parameter"} $files) \
        2> "$out/$case/protoc.err" || true
    mkdir -p "$out/$case/bufws" && cp -RL "$input"/. "$out/$case/bufws/"
    printf 'version: v2\n' > "$out/$case/bufws/buf.yaml"
    {
        printf 'version: v2\nplugins:\n  - local: %s\n    out: %s\n' "$plugin" "$out/$case/buf"
        if [[ -n $parameter ]]; then
            printf '    opt:\n'
            for pair in "${pairs[@]}"; do printf '      - %s\n' "$pair"; done
        fi
    } > "$out/$case/buf.gen.yaml"
    (cd "$out/$case/bufws" && mise exec -C "$root" -- buf generate "$out/$case/bufws" \
        --template "$out/$case/buf.gen.yaml") 2> "$out/$case/buf.err" || true
    if [[ -f $case_dir/expected/diagnostics.txt ]]; then
        # Each problem's code ends a line, alone or after a front end's prefix.
        codes() { grep -oE '(^|: )[a-z]+::[a-z_]+$' "$1" | sed 's/^: //' | sort | uniq -c | tr -s ' ' | tr '\n' ';'; }
        printf '%s\tdiagnostics\texpected=%s\tcli=%s\tprotoc=%s\tbuf=%s\n' "$case" \
            "$(codes "$case_dir/expected/diagnostics.txt")" "$(codes "$out/$case/cli.err")" \
            "$(codes "$out/$case/protoc.err")" "$(codes "$out/$case/buf.err")"
        printf '  protoc says: %s\n  buf says: %s\n' "$(head -1 "$out/$case/protoc.err")" \
            "$(head -1 "$out/$case/buf.err")"
        continue
    fi
    cp -R "$case_dir/expected"/. "$out/$case/expected/"
    rm -f "$out/$case/expected/warnings.txt"
    find "$out/$case/expected" -name '*.elm' -exec sed -i.bak "s/$placeholder/$version/g" {} \;
    find "$out/$case/expected" -name '*.bak' -delete
    result=""
    for front in protoc buf expected; do
        if diff -r "$out/$case/cli" "$out/$case/$front" > "$out/$case/$front.diff"; then
            result+="$front=same "
        else
            result+="$front=DIFFERS "
            rc=1
        fi
    done
    printf '%s\t%s modules\t%s\n' "$case" "$(find "$out/$case/cli" -name '*.elm' | wc -l | tr -d ' ')" "$result"
done
exit $rc
