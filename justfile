clay_cpu_flags := if arch() == "x86_64" { "-march=x86-64 -mtune=generic" } else { "" }
release_arch := if arch() == "aarch64" { "arm64" } else { "x64" }

default:
	@just --list

build: clay
	odin build . -out:build/stuff -debug

release: clay
	odin build . -out:build/stuff -o:speed -source-code-locations:filename -no-rpath -extra-linker-flags:"-s"

# build the release archive for the native architecture.
bundle: release
	sh packaging/linux/bundle.sh build/release/stuff-linux-{{release_arch}}.tar.zst

test-packaging:
	bash scripts/test-packaging.sh

check-packaging:
	shellcheck packaging/linux/*.sh scripts/*.sh
	shellcheck --shell=bash --exclude=SC2034,SC2154 packaging/aur/stuff-bin/PKGBUILD.in packaging/aur/stuff-git/PKGBUILD
	desktop-file-validate assets/stuff.desktop

check:
	odin check . -vet -strict-style

check-arm:
	odin check . -vet -strict-style -target:linux_arm64

test: clay
	SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software odin test . -out:build/stuff-tests -define:ODIN_TEST_THREADS=1

# exercise real drag negotiation in a private headless Wayland compositor (labwc).
test-drag: clay
	odin test . -out:build/stuff-drag-tests -define:ODIN_TEST_THREADS=1 -define:NATIVE_WAYLAND_TESTS=true -define:ODIN_TEST_NAMES=main.native_wayland_file_drag

fmt:
	odinfmt . -w

run folder=".": build
	./build/stuff {{quote(folder)}}

# draw one frame without a desktop session.
smoke: build
	SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software ./build/stuff --smoke

# draw one frame in the current Wayland session.
smoke-wayland: build
	SDL_VIDEODRIVER=wayland ./build/stuff --smoke

# build the pinned Clay source for the native architecture.
clay: _dirs
	cc -std=c99 -O3 -fPIC {{clay_cpu_flags}} -DCLAY_IMPLEMENTATION -x c -c vendor/clay/clay.h -o build/clay.o
	ar rcsD vendor/clay/linux/clay.a build/clay.o

_dirs:
	mkdir -p build vendor/clay/linux
