# Keeping the AArch64 port current with upstream MAKO releases

This fork carries the native AArch64 port described in [plugin/docs/ARMADA.md](plugin/docs/ARMADA.md) on `port/aarch64`. It follows **published releases** of [eugeniosegala/MAKO](https://github.com/eugeniosegala/MAKO), never unreleased commits, and publishes a matching AArch64 release only with the maintainer's approval:

```text
upstream publishes plugin-vX.Y.Z (GitHub's Latest release)
        |
        v  upstream-sync.yml, every six hours or on dispatch
"Sync upstream release plugin-vX.Y.Z" pull request -> port/aarch64
        |  AArch64 + Tests CI, DroidDeck tester ZIP, x86-assumption audit
        v  maintainer reviews, tests on hardware, and merges (approval)
aarch64-release.yml rebuilds, retests, and publishes aarch64-vX.Y.Z
```

## Release sync

[`.github/workflows/upstream-sync.yml`](.github/workflows/upstream-sync.yml) reads upstream's Latest release. A MAKO release publishes the Renderer (`render-v*`) before MAKO Decky (`plugin-v*`), and the Decky release becomes Latest, so the sync waits until both are out.

| Upstream state | Result |
| --- | --- |
| Latest release already contained in `port/aarch64` | Nothing. |
| New release that merges cleanly | Merges its tag into the `upstream-sync` branch and opens or updates the `Sync upstream release …` pull request. The `AArch64` and `Tests` workflows run on it, and `AArch64` retains the `mako-aarch64-tester-package` artifact. |
| New release that conflicts with the port | Opens the pull request from the release tag, titled `(conflicts)`, listing the files to resolve. |
| A pull request already proposes this release | Nothing, so CI does not rerun needlessly. |
| A newer release arrives while a pull request is pending | Merges it on top of the pending branch, preserving any conflict resolution pushed there. |

Each pull request includes `scripts/upstream-sync-audit.sh` output: the release's commits, changed files, and added code lines naming x86-only identities (ISA names, `lib32`, 32-bit manifests, Gamescope WSI, MangoHud, Steam overlay, host-architecture metadata). Those lines are where a new feature may need an AArch64 counterpart, such as a `constants.host_layer_identities()` entry, a wrapper or `mako-launch` branch, or a packager rule. Prose, the website, and the x86_64-only Flatpak and Arch packages are excluded.

## Approving a release

1. Wait for `AArch64` and `Tests` to pass on the pull request. A failure means the release needs porting before merge.
2. Review every audit finding. Port it, or confirm it is x86-only by design (Flatpak, Remote Play, 32-bit payloads).
3. Install the pull request's `mako-aarch64-tester-package` ZIP on DroidDeck and check `collect-aarch64-evidence.sh` output.
4. Merge with a **merge commit** (not squash or rebase), so the release tag stays in the port's history.

That merge is the approval: [`.github/workflows/aarch64-release.yml`](.github/workflows/aarch64-release.yml) rebuilds and retests the package natively on arm64, checks that `plugin/RELEASE_NOTES.md` describes the same version, and publishes `aarch64-vX.Y.Z` with the Decky ZIP, the Renderer archive, the evidence collector, and `SHA256SUMS`. For a second approval after the build and before publication, add required reviewers to the `aarch64-release` environment.

Other pushes to `port/aarch64` (port fixes, the initial push) never publish. Resolve conflicts with GitHub's conflict editor, or locally by merging the release tag into `port/aarch64`, keeping both the upstream behavior and its AArch64 counterpart.

## Manual releases

Run `AArch64 release` from the Actions tab to publish the newest upstream release already merged into the port. Use this for the first release after setup. Published tags and assets are never replaced: to ship a port fix for an already published version, dispatch with `revision` `2`, `3`, … to publish `aarch64-vX.Y.Z-rN`.

## One-time setup

1. Push `port/aarch64` to the fork and make it the fork's **default branch**. GitHub runs scheduled workflows only from the default branch.
2. Enable Actions for the fork, and enable the sync workflow if GitHub lists it as disabled.
3. Create a fine-grained personal access token restricted to the fork, with **Contents**, **Pull requests**, and **Workflows** read/write access. Save it as the repository secret `MAKO_SYNC_TOKEN`. `GITHUB_TOKEN` cannot push upstream changes to workflow files, and pull requests it opens do not start CI. Releases use `GITHUB_TOKEN`.
4. Optionally protect `port/aarch64` so that a merge requires the `AArch64` checks, and add reviewers to the `aarch64-release` environment.
5. Optionally disable upstream-only workflows the fork does not need: `MAKO Cleaner` closes inactive issues, and the Pages deployment publishes the upstream website.

`UPSTREAM_REPOSITORY`, `UPSTREAM_RELEASE_PREFIX`, `PORT_BRANCH`, and `SYNC_BRANCH` at the top of the workflows select the repositories and branches. Renew the token before it expires; an expired token makes the sync fail at checkout.
