#!/usr/bin/env bash
# Fetch the Connect conformance suite's runner, connectconformance, from its
# GitHub release at the pinned version, check the archive against the pinned
# SHA-256 (from the release's connectconformance_<version>_checksums.txt), and
# unpack it into build/connectconformance-<version>/. Prints the binary's path.
# Does nothing but print it when it is already there.
set -euo pipefail

version=v1.0.6

here="$(cd "$(dirname "$0")" && pwd)"
dir="$here/build/connectconformance-$version"
bin="$dir/connectconformance"
if [[ -x "$bin" ]]; then
  echo "$bin"
  exit 0
fi

os="$(uname -s)"
arch="$(uname -m)"
case "$os-$arch" in
  Darwin-arm64) sha256=b736e0ea69447ed663ba9298894faa75b0ff6dbd5e0c9acb63bedde46b1f7d8a ;;
  Darwin-x86_64) sha256=0920c4612593301fd7cfdee6256bfaf3232dc5e21aeda1a9b2e6bcc6be806458 ;;
  Linux-aarch64 | Linux-arm64) arch=aarch64; sha256=718b6b255b185f76bbb149978be4a6067d7379e5195486f35b6d41dc8301ca4d ;;
  Linux-x86_64) sha256=803a9ed1778583f9b98f44b4b77ab06897d1027183ef2064de32a0fb7d688ab0 ;;
  *) echo "fetch-conformance.sh: no pinned connectconformance for $os-$arch" >&2; exit 1 ;;
esac

asset="connectconformance-$version-$os-$arch.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$asset" "https://github.com/connectrpc/conformance/releases/download/$version/$asset"
actual="$( (command -v sha256sum >/dev/null && sha256sum "$tmp/$asset" || shasum -a 256 "$tmp/$asset") | cut -d' ' -f1)"
if [[ "$actual" != "$sha256" ]]; then
  echo "fetch-conformance.sh: $asset has SHA-256 $actual, expected $sha256" >&2
  exit 1
fi
mkdir -p "$tmp/unpacked"
tar -xzf "$tmp/$asset" -C "$tmp/unpacked"
mkdir -p "$dir"
mv "$tmp/unpacked/connectconformance" "$bin"
chmod +x "$bin"
echo "$bin"
