#!/usr/bin/env bash
# Fetch the protobuf conformance suite's runner, conformance_test_runner, as
# bufbuild/protobuf-conformance publishes it prebuilt from protobuf's
# conformance/ at the pinned release, check the archive against the pinned
# SHA-256 (the digest GitHub reports for the release asset), and unpack it
# into spike/conformance-runner/<version>/ (gitignored). Prints the
# directory. Does nothing but print it when it is already there. macOS gets
# the x86_64 build, which runs under Rosetta on arm64.
set -euo pipefail

version=v32.0-rc2

root="$(cd "$(dirname "$0")/../.." && pwd)"
dir="$root/spike/conformance-runner/$version"
if [[ -x "$dir/bin/conformance_test_runner" ]]; then
  echo "$dir"
  exit 0
fi

case "$(uname -s)" in
  Darwin) platform=osx-x86_64; sha256=9c01b26eface95c277eb4c08de09536ad6605434632c9e3682ee4d5b553ad280 ;;
  Linux) platform=linux-x86_64; sha256=d53590d6cda2b59a8e4b21e95dc429bc1b2b6fe8d484d6fbaab1f411c743ed85 ;;
  *) echo "fetch-runner.sh: no pinned conformance_test_runner for $(uname -s)" >&2; exit 1 ;;
esac

asset="conformance_test_runner-${version#v}-$platform.zip"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$asset" "https://github.com/bufbuild/protobuf-conformance/releases/download/$version/$asset"
actual="$( (command -v sha256sum >/dev/null && sha256sum "$tmp/$asset" || shasum -a 256 "$tmp/$asset") | cut -d' ' -f1)"
if [[ "$actual" != "$sha256" ]]; then
  echo "fetch-runner.sh: $asset has SHA-256 $actual, expected $sha256" >&2
  exit 1
fi
mkdir -p "$dir"
unzip -q -o "$tmp/$asset" -d "$dir"
echo "$dir"
