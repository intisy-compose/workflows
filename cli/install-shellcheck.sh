#!/bin/bash
# install-shellcheck.sh DIRECTORY: puts the shellcheck release pinned in shellcheck.pin into
# DIRECTORY, checked against its pinned sha256, so a runner image update cannot change the verdicts.
# Linux x86_64 only, as the CI runners are.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
target=${1:?names the directory to install shellcheck into}
version=$(sed -n 's/^version //p' "$here/shellcheck.pin")
checksum=$(sed -n 's/^sha256 //p' "$here/shellcheck.pin")
archive="shellcheck-v$version.linux.x86_64.tar.xz"
download=$(mktemp -d)
trap 'rm -rf "$download"' EXIT

curl -fsSL -o "$download/$archive" "https://github.com/koalaman/shellcheck/releases/download/v$version/$archive"
echo "$checksum  $download/$archive" | sha256sum -c --quiet -
tar -xJf "$download/$archive" -C "$download"
mkdir -p "$target"
install -m 0755 "$download/shellcheck-v$version/shellcheck" "$target/shellcheck"
"$target/shellcheck" --version | grep '^version:'
