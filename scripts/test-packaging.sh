#!/usr/bin/env bash
set -euo pipefail
archives=${1:-build/release}
out="$PWD/build/package-tests"
checksum_x86_64=$(sha256sum "$archives/stuff-linux-x64.tar.zst")
if [[ -f "$archives/stuff-linux-arm64.tar.zst" ]]; then
	checksum_aarch64=$(sha256sum "$archives/stuff-linux-arm64.tar.zst")
else
	# makepkg on x86-64 never fetches the aarch64 source; the release sets the real digest.
	echo "no aarch64 archive in $archives; the recipe gets a placeholder digest" >&2
	checksum_aarch64="$(printf '0%.0s' {1..64})  placeholder"
fi
bash scripts/prepare-aur.sh 0.0.0 "${checksum_x86_64%% *}" "${checksum_aarch64%% *}" "$out"

# use the local archive; never download an unpublished test release.
cp "$archives/stuff-linux-x64.tar.zst" "$out/stuff-bin/stuff-bin-0.0.0-linux-x64.tar.zst"
makepkg --dir "$out/stuff-bin" --force --noconfirm

# build the current checkout rather than the older public main branch.
source="$out/stuff-git/src/stuff"
mkdir -p "$source"
tar --exclude='./.git' --exclude='./build' -cf - . | tar -xf - -C "$source"
makepkg --dir "$out/stuff-git" --noextract --force --noconfirm

for package in stuff-bin stuff-git; do
	directory="$out/$package"
	report=$(namcap "$directory/PKGBUILD" "$directory/"*.pkg.tar.zst)
	printf '%s\n' "$report"
	if [[ $report == *' E: '* ]]; then exit 1; fi
	root="$directory/pkg/$package"
	test -f "$root/usr/share/applications/stuff.desktop"
	test -f "$root/usr/share/dbus-1/services/stuff.FileManager1.service"
	test ! -e "$root/usr/share/dbus-1/services/org.freedesktop.FileManager1.service"
	test -f "$root/usr/share/icons/hicolor/scalable/apps/stuff.svg"
	for license in LICENSE clay.txt lucide.txt; do
		test -s "$root/usr/share/licenses/$package/$license"
	done
	SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software "$root/usr/bin/stuff" --smoke --select "$root/usr/share/applications/stuff.desktop"
done
