# clay

source: https://github.com/nicbarker/clay

revision: `e6cc36941ab2af5d81107617039d6f527a1c660b`

- `clay.h` is unchanged upstream source.
- `clay.odin` is the upstream Odin binding, formatted with `odinfmt`, with Linux architecture selection added.
- `LICENSE` is the upstream license.
- `linux/clay.a` is the Linux x86-64 archive, built with GCC 16.2.1.
- `linux-arm64/clay.a` is the Linux arm64 archive, built with Clang and LLVM ar 23.1.4 for ARMv8-A.

normal builds and tests use these archives without compiling Clay. both use C99, `-O3`, and `-fPIC`. x86-64 uses generic CPU settings.

run `just clay` to rebuild the archive for the native Linux architecture after a Clay update. this explicit command requires a C compiler and `ar`.

the arm64 archive can also be rebuilt with Clang without a target sysroot:

```sh
mkdir -p build vendor/clay/linux-arm64
clang --target=aarch64-linux-gnu -ffreestanding -std=c99 -O3 -fPIC -march=armv8-a -mtune=generic -DCLAY_IMPLEMENTATION -x c -c vendor/clay/clay.h -o build/clay.o
llvm-ar rcsD vendor/clay/linux-arm64/clay.a build/clay.o
```

other target archives are not included.
