#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
version=$(tr -d '\r\n' < VERSION)
if ! grep -q "LapVersion = '$version';" src/lapMain.pas; then
  echo "VERSION says $version, but LapVersion in src/lapMain.pas differs." >&2
  exit 1
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
  echo 'VERSION must contain a semantic version.' >&2
  exit 1
fi
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p dist
opt='-g- -O2 -Xs -XX -CX'

# The files every package holds, beside the executable.
stage_package() {
  mkdir -p "$stage/$1/icons" "$stage/$1/images"
  cp "$2" README.md LICENSE CHANGELOG.md VERSION "$stage/$1/"
  cp icons/lazasspicker.png "$stage/$1/icons/"
  cp images/main.png "$stage/$1/images/"
}

./build.sh --cpu=x86_64 --os=linux --ws=gtk3 --opt="$opt" "$@"
linux="lazasspicker-$version-linux-x86_64"
stage_package "$linux" bin/lazasspicker
epoch=${SOURCE_DATE_EPOCH:-0}
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
  -czf "dist/$linux.tar.gz" -C "$stage" "$linux"

./build.sh --cpu=x86_64 --os=win64 --ws=win32 --opt="$opt" "$@"
windows="lazasspicker-$version-windows-x86_64"
stage_package "$windows" bin/lazasspicker.exe
rm -f "dist/$windows.zip"
(cd "$stage" && zip -qrX - "$windows") > "dist/$windows.zip"

(
  cd dist
  sha256sum "$linux.tar.gz" > "$linux.tar.gz.sha256"
  sha256sum "$windows.zip" > "$windows.zip.sha256"
)
printf 'Built %s and %s\n' "dist/$linux.tar.gz" "dist/$windows.zip"
