# stuff

lightweight file manager for linux

## features

- keyboard navigation and back/forward history
- places and disks sidebar with mounting and free-space updates
- multiselect, copy, paste, and move to trash
- sortable file details and an editable path
- open files with their default application
- light and dark themes with the system monospace font

## built with

- [odin](https://odin-lang.org/)
- [sdl3](https://www.libsdl.org/)
- [clay](https://github.com/nicbarker/clay)

## install

### arch

```sh
paru -S stuff-bin
```

```sh
paru -S stuff-git
```

## development

> requires odin, just, SDL3, SDL3_ttf, SDL3_image with SVG support, libudev, libdbus, fontconfig, and glib2. mounting requires UDisks2 and a desktop authorization agent. tests use dbus-daemon.

```sh
just build
just run
just test
```
