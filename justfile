default:
	@just --list

build: _dirs
	odin build . -out:build/stuff -debug

release: _dirs
	odin build . -out:build/stuff -o:speed -extra-linker-flags:"-s"

check:
	odin check . -vet -strict-style

test: _dirs
	SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software odin test . -out:build/stuff-tests -define:ODIN_TEST_THREADS=1

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

# rebuild the vendored Linux x86-64 library after a Clay update.
clay: _dirs
	cc -std=c99 -O3 -fPIC -march=x86-64 -mtune=generic -DCLAY_IMPLEMENTATION -x c -c vendor/clay/clay.h -o build/clay.o
	ar rcsD vendor/clay/linux/clay.a build/clay.o

_dirs:
	mkdir -p build vendor/clay/linux
