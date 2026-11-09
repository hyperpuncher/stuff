# stuff

lightweight file manager for linux

## features

- keyboard navigation with `hjkl`
- places and disks sidebar with back/forward history
- volume usage bars and automatic free-space updates
- mount on open; unmount with the disk button or `ctrl+e` in the sidebar
- sortable name, size, and modified columns
- multiselect, background copy and paste, and move to trash
- right-click menu and GNOME/KDE file clipboard formats
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

## file actions

use `ctrl+click` to toggle items, `shift+click` or `shift+up/down` to select a range, and `ctrl+a` to select all shown items.

copy with `ctrl+c` or `ctrl+insert`. paste with `ctrl+v` or `shift+insert`. existing items are kept; copies get a new name when needed. symbolic links are copied as links.

`delete` moves selected items to trash. if trash is unavailable, the items stay in place. permanent delete, cut/move, rename, and search are not implemented yet.
