#!/usr/bin/env bash
# Fetch the Connect conformance suite's runner, connectconformance, from its
# GitHub release at the pinned version, check the archive against the pinned
# SHA-256 (from the release's connectconformance_<version>_checksums.txt), and
# unpack it into build/connectconformance-<version>/. Prints the binary's path.
# Does nothing but print it when it is already there.
set -euo pipefail

version=v1.0.7

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
  Darwin-arm64) sha256=6e3534f8a39ad91843913af80fa7f68fdc266a71560b00ad078a0637d380100b ;;
  Darwin-x86_64) sha256=969de3f343c67bebe37db2a1641c2ced15d44ddd358400de24cbb53e28d3a561 ;;
  Linux-aarch64 | Linux-arm64) arch=aarch64; sha256=c43e11cdca4cf7936a502fa25e1d7f27a6475b806d0ab5647668a5777b9d2121 ;;
  Linux-x86_64) sha256=cf2d7c671c8cfbdfba5e48dc58cbe0b2db01fa7b1c160ecf060f20d27479d63c ;;
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
