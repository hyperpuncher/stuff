# stuff

lightweight file manager for linux

## features

- keyboard navigation with `hjkl`
- places and disks sidebar with back/forward history
- volume usage bars and automatic free-space updates
- mount on open; unmount with the disk button or `ctrl+e` in the sidebar
- sortable name, size, and modified columns
- clickable path breadcrumbs and a copy-path button
- open files with their default system application
- system monospace font and neutral lucide icons

## built with

- [odin](https://odin-lang.org/)
- [sdl3](https://www.libsdl.org/)
- [clay](https://github.com/nicbarker/clay)

## development

> requires odin, just, SDL3, SDL3_ttf, SDL3_image with SVG support, libudev, libdbus, fontconfig, and xdg-utils. mounting requires UDisks2 and a desktop authorization agent. tests use dbus-daemon on a private bus.

```sh
just build
just run
just test
```

> work in progress. copy, move, rename, delete, and search are not implemented yet.
