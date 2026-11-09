# clay

source: https://github.com/nicbarker/clay

revision: `e6cc36941ab2af5d81107617039d6f527a1c660b`

- `clay.h` is unchanged upstream source.
- `clay.odin` is the upstream Odin binding, formatted with `odinfmt`.
- `LICENSE` is the upstream license.
- `linux/clay.a` is built from the included header for Linux x86-64.

the archive was built with GCC 16.2.1, C99, `-O3`, `-fPIC`, and generic x86-64 CPU settings. the exact build command is in the `clay` recipe.

build and test recipes rebuild the archive from the pinned source for the native Linux architecture. x86-64 uses generic CPU settings; arm64 uses the compiler's default target. this requires a C compiler and `ar`.

other target archives are not included.
