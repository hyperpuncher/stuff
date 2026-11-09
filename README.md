# stuff

lightweight file manager for linux

## features

- keyboard navigation with `hjkl`
- places sidebar and back/forward history
- sortable name, size, and modified columns
- clickable path breadcrumbs and a copy-path button
- open files with their default system application
- system monospace font and neutral lucide icons

## built with

- [odin](https://odin-lang.org/)
- [sdl3](https://www.libsdl.org/)
- [clay](https://github.com/nicbarker/clay)

## development

> requires odin, just, SDL3, SDL3_ttf, SDL3_image with SVG support, fontconfig, and xdg-utils

```sh
just build
just run
just test
```

> work in progress. copy, move, rename, delete, and search are not implemented yet.
