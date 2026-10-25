#!/usr/bin/env bash
# Fetch the protobuf conformance suite's runner, conformance_test_runner,
# built from protobuf's conformance/ at the pinned release and published
# prebuilt by bufbuild/protobuf-conformance (protobuf's own releases ship
# protoc alone). Check the archive against the SHA-256 pinned per platform
# (the digest GitHub reports for the release asset) before unpacking it into
# build/conformance_test_runner-<version>/, and print that directory. Does
# nothing but print it when the runner is already there. macOS gets the
# x86_64 build, which runs under Rosetta on arm64.
set -euo pipefail

version=v32.0-rc2

here="$(cd "$(dirname "$0")" && pwd)"
dir="$here/build/conformance_test_runner-$version"
if [[ -x "$dir/bin/conformance_test_runner" ]]; then
  echo "$dir"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-*) platform=osx-x86_64; sha256=9c01b26eface95c277eb4c08de09536ad6605434632c9e3682ee4d5b553ad280 ;;
  Linux-x86_64) platform=linux-x86_64; sha256=d53590d6cda2b59a8e4b21e95dc429bc1b2b6fe8d484d6fbaab1f411c743ed85 ;;
  *) echo "fetch-runner.sh: no pinned conformance_test_runner for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
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
mkdir -p "$tmp/unpacked"
unzip -q "$tmp/$asset" -d "$tmp/unpacked"
mkdir -p "$here/build"
rm -rf "$dir"
mv "$tmp/unpacked" "$dir"
echo "$dir"
