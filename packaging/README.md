# releases and AUR

stable `vX.Y.Z` tags build Linux x86-64 and arm64 archives. release notes come from `hyperpuncher/release-notes@v1`. AUR recipes use GitHub's asset digests.

both architectures run checks, tests, and a private headless Wayland drag test on native runners. an Arch container also builds and checks both AUR recipes on x86-64 before publication.

`stuff-bin` installs a release binary. `stuff-git` builds the main branch with Odin. VCS recipes are not updated for release-only version changes. the publisher preserves package revisions, rejects binary-package downgrades, and pushes only changed recipes.

## setup

add the `AUR_KEY` repository secret. use an SSH private key without a passphrase, with write access to both AUR repositories. the workflow checks the pinned AUR host key.

## local checks

```sh
just check-packaging
just bundle
just test-packaging
```

package tests need both release archives, Arch's `makepkg`, a non-root user, runtime and build dependencies, `namcap`, and a monospace font.

these commands do not publish anything. pushing a release tag starts publication. if the AUR job fails, retry the existing release with `gh workflow run aur.yml -f tag=vX.Y.Z`. this does not rebuild assets or move the tag.
