#!/bin/sh
set -eu
# run from the source tree or extracted release archive.
dest=${1:?package root required}
package=${2:?package name required}
install -Dm755 build/stuff "$dest/usr/bin/stuff"
install -Dm644 assets/stuff.desktop "$dest/usr/share/applications/stuff.desktop"
# keep activation opt-in; do not compete with other installed file managers.
install -Dm644 assets/org.freedesktop.FileManager1.service "$dest/usr/share/stuff/org.freedesktop.FileManager1.service"
install -Dm644 assets/stuff.svg "$dest/usr/share/icons/hicolor/scalable/apps/stuff.svg"
licenses="$dest/usr/share/licenses/$package"
install -Dm644 LICENSE "$licenses/LICENSE"
install -Dm644 vendor/clay/LICENSE "$licenses/clay.txt"
install -Dm644 vendor/lucide/LICENSE "$licenses/lucide.txt"
