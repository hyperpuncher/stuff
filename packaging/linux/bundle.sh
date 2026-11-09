#!/bin/sh
set -eu
out=${1:?output .tar.zst path required}
mkdir -p "$(dirname "$out")"
tar --zstd -cf "$out" \
	build/stuff \
	assets/stuff.desktop \
	assets/stuff.svg \
	packaging/linux/install.sh \
	LICENSE \
	vendor/clay/LICENSE \
	vendor/lucide/LICENSE
