#!/usr/bin/env bash
set -euo pipefail
version=${1:?release version required}
checksum_x86_64=${2:?x86-64 checksum required}
checksum_aarch64=${3:?arm64 checksum required}
out=${4:?output directory required}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "expected a stable release version" >&2; exit 1; }
[[ $checksum_x86_64 =~ ^[[:xdigit:]]{64}$ && $checksum_aarch64 =~ ^[[:xdigit:]]{64}$ ]] || { echo "missing or invalid release asset digests" >&2; exit 1; }
mkdir -p "$out/stuff-bin" "$out/stuff-git"
sed -e "s/@VERSION@/$version/g" \
	-e "s/@SHA256_X86_64@/$checksum_x86_64/g" \
	-e "s/@SHA256_AARCH64@/$checksum_aarch64/g" \
	packaging/aur/stuff-bin/PKGBUILD.in > "$out/stuff-bin/PKGBUILD"
cp packaging/aur/stuff-git/PKGBUILD "$out/stuff-git/PKGBUILD"
for package in stuff-bin stuff-git; do
	(cd "$out/$package" && makepkg --printsrcinfo > .SRCINFO)
done
