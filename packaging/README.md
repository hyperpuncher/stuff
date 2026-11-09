# releases and AUR

stable `vX.Y.Z` tags build Linux x86-64 and arm64 archives and a `SHA256SUMS` file. release notes come from `hyperpuncher/release-notes@v1`.

both architectures run checks, tests, and a private headless Wayland drag test on native runners. an Arch container also builds and checks both AUR recipes on x86-64 before publication.

`stuff-bin` installs a release binary. `stuff-git` builds the main branch with Odin. VCS recipes are not updated for release-only version changes. the publisher preserves package revisions, rejects binary-package downgrades, and pushes only changed recipes.

## setup

add the `AUR_KEY` repository secret. use an SSH private key without a passphrase, with write access to both AUR repositories. the workflow checks the pinned AUR host key.

## local checks

```sh
just check-packaging
just bundle
bash scripts/prepare-aur.sh 0.1.0 build/release build/aur
just test-packaging
```

recipe generation needs both release archives, Arch's `makepkg`, and a non-root user. package tests also need the runtime and build dependencies, `namcap`, and a monospace font.

these commands do not publish anything. publishing starts only when a release tag is pushed.
