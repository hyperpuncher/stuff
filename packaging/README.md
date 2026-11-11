# releases and AUR

stable `vX.Y.Z` tags build Linux x86-64 and arm64 archives. release notes come from `hyperpuncher/release-notes@v1`. AUR recipes use GitHub's asset digests.

both architectures run checks, tests, and a private headless Wayland drag test on native runners. an Arch container also builds and checks both AUR recipes in parallel on x86-64, before publication.

`stuff-bin` installs a release binary. `stuff-git` builds the main branch with Odin. VCS recipes are not updated for release-only version changes. the publisher preserves package revisions, rejects binary-package downgrades, and pushes only changed recipes.

## file-manager integration

`xdg-mime default stuff.desktop inode/directory` selects stuff for opening folders.

`ShowItems` and `ShowFolders` use the separate `org.freedesktop.FileManager1` session service. the package installs `/usr/share/dbus-1/services/stuff.FileManager1.service` active, so browsers can reveal files at once. the file name differs from Nautilus's `org.freedesktop.FileManager1.service` to avoid a package file conflict, but both define the same bus name.

when several installed services define that name in one directory, the daemon picks one without a rule. to choose the provider per user, link its service file into `${XDG_DATA_HOME:-~/.local/share}/dbus-1/services`, as described in `File manager functionality#D-Bus`. the per-user file wins over `/usr/share`. kill a running provider first; it keeps the name until it exits.

properties requests return `NotSupported` until stuff has a properties dialog.

## setup

add the `AUR_KEY` repository secret. use an SSH private key without a passphrase, with write access to both AUR repositories. the workflow checks the pinned AUR host key.

## local checks

archive operations link to the system libarchive library. Ubuntu builds need `libarchive-dev`; Arch packages need `libarchive`.

```sh
just check-packaging
just bundle
just test-packaging
```

package tests use the native release archive in `build/release`. without an aarch64 archive the aarch64 recipe gets a placeholder digest, which is enough because makepkg on x86-64 never fetches it. the release workflow sets the real digests. the tests also need Arch's `makepkg`, a non-root user, runtime and build dependencies, `namcap`, and a monospace font.

these commands do not publish anything. pushing a release tag starts publication. if the AUR job fails, retry the existing release with `gh workflow run aur.yml -f tag=vX.Y.Z`. this does not rebuild assets or move the tag.
