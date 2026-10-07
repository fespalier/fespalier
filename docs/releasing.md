# Releasing

Maintainers only. Releases are cut with release-please, the convention of every repository in the
vaam-apps organization. Its guide, `docs/releasing.md` in `vaam-apps/.github`, lists the ways this has
failed silently and is worth reading before changing anything here.

Nobody bumps a version by hand, edits `.release-please-manifest.json`, or runs a workflow to publish.

**The flow.**

1. **Land conventional commits.** The repository squash-merges and the pull request _title_ becomes
   the commit subject, which is all release-please reads: `feat:`, `fix:`, `docs:`, `ci:` and the other
   conventional types. `pr-title` refuses anything else; a subject it cannot read is ignored, and no
   release PR appears.
   - `feat` and `fix` decide the bump (before 1.0 a breaking change bumps the minor); every other
     visible type is a patch.
   - To force a version, put a `Release-As: X.Y.Z` footer in a commit.
2. **The release PR.** Every push to `main` updates one standing pull request from the branch
   `release-please--branches--main`. It bumps the version in `cli/Cargo.toml`,
   `packages/fespalier/pubspec.yaml`, the `ref:` that `fsp init` prints, the READMEs' and docs pages' install snippets
   and `.release-please-manifest.json`, and it writes the root `CHANGELOG.md` above the hand-written
   history. The `release-please` workflow refreshes `cli/Cargo.lock` on the branch, because the build is
   `--locked`.
   - Every spelled-out version carries a release-please annotation and is listed in
     `release-please-config.json`. The trailing comment is why every reader of those files must
     tolerate one (see `scripts/read-version.sh`).
   - Nothing else sits on an annotated line or inside a start/end block, because the updater replaces
     the first version on each of them, so a dependency's range there would be overwritten.
3. **Pins, on the PR.** The `Release pins` workflow builds `fsp` for the five targets on the PR branch,
   stages the archives, and commits their SHA-256s to the branch as `chore: pin fsp X.Y.Z checksums`
   (`packages/fespalier/lib/src/release_checksums.dart`, `scripts/pin_checksums.py`).
   - release-please force-pushes the branch whenever `main` moves, which removes that commit; the
     workflow then runs again on the new head. It recognises its own commit and does not loop.
   - The `fsp` build reads only `cli/`, never `release_checksums.dart`, so the pin commit does not
     change the binaries.
   - Wait for the `Release pins gate` check before merging (make it required in the `main` ruleset;
     other pull requests pass it by skipping).
   - The archives wait in a _staging_ draft release named `fsp-staging` (visible to maintainers,
     replaced by every build, deleted after the release), not in workflow artifacts, which expire.
4. **Merge the release PR.** release-please (as the org's GitHub App, so that the tag raises a workflow
   event) creates the tag `vX.Y.Z` at the merge commit and a _draft_ GitHub Release. The `Release`
   workflow, triggered by the tag, then
   - checks that the tag equals the Cargo, pubspec, manifest and lockfile versions;
   - fetches the staged archives and **refuses anything that is not the pinned build**
     (`scripts/verify-staged.sh`): they must be this version, built from the `cli/` tree that is
     tagged, and every archive's SHA-256 must equal the pin in the tagged tree. It never rebuilds:
     builds are not reproducible, so a rebuild could not match the pins;
   - regenerates the `.sha256` files and renders `fsp.rb` (Homebrew) and `fsp.json` (Scoop) from the
     verified archives (`scripts/packaging.py`), attaches all of it to the draft Release, publishes it
     (only now is it public and the latest release), and deletes the staging draft;
   - if the repository variable `HOMEBREW_TAP` is set (`owner/repo`), pushes `fsp.rb` to that Homebrew
     tap, and if `SCOOP_BUCKET` is set, pushes `fsp.json` to that Scoop bucket. Each is its own job and
     optional: unset, it is skipped and the release is complete, with `fsp.rb` and `fsp.json` still
     attached as assets.

   A git dependency on the new tag therefore carries the pins, and `dart run fespalier` refuses any
   download that does not match them (a checksum served next to the binary can be replaced together
   with it; one in the package cannot).

0.8.0 was tagged but never published (its binaries were built before the last change); the wave it
carried ships as 0.8.1.

Between releases, `main` still carries the last release's pins. On an open release PR, before its pin
commit, the pubspec is ahead of them; the launcher then falls back to the release's `.sha256` with a
warning, as for any development build. `cli/tests/versions.rs` accepts pins for the current or an older
version, never a newer one.

**If something fails.** A failed `Release` run leaves the release a draft (nobody sees it, and `latest`
does not move): fix the cause and re-run the failed jobs.

- The usual causes are a `cli/` change that reached `main` after the last build (the release PR was
  merged before its head was rebuilt: make `Release pins gate` required and the branch up to date before
  merging), or staged binaries that were replaced or deleted.
- If the merged commit cannot be made to match, delete the draft and the tag and fix forward with the
  next release.
- A manual run of `Release` (_Run workflow_) only builds the five targets and renders the Homebrew and
  Scoop files as a smoke test; it publishes nothing.

**Repository settings** (not enforceable from a workflow): squash merging only, with the squash commit
title set to the pull request title and the message to the commit messages; merge commits and rebase
merges off. The release-please GitHub App must be installed on this repository, and on the tap and the
bucket if you set `HOMEBREW_TAP` or `SCOOP_BUCKET`.

**The Homebrew tap and the Scoop bucket are optional.** A release publishes without them, with `fsp.rb`
and `fsp.json` attached as assets. Each is its own job in the `Release` workflow, gated on a repository
variable holding `owner/repo`, so either alone works:

- `HOMEBREW_TAP` = `fespalier/homebrew-tap`. The job writes `Formula/fsp.rb`. The `homebrew-`
  prefix is what lets `brew tap fespalier/tap` and `brew install fespalier/tap/fsp` find it.
- `SCOOP_BUCKET` = `fespalier/scoop-bucket`. The job writes `bucket/fsp.json`. The manifest's
  `checkver` and `autoupdate` let Scoop's own tooling keep the bucket current too.

To set them up, once:

1. Create the two repositories, and install the release-please App on them with `contents: write`.
2. Set the variables under _Settings_, _Secrets and variables_, _Actions_, _Variables_ here.

The repositories may be brand new with only a README. The job checks out the repository's **default
branch** (`main` for a new repository; it never assumes `master`: it pushes back to whichever branch the
checkout is on), creates `Formula/` or `bucket/` when it is missing, and commits `fsp X.Y.Z`. A
repository with no commit at all cannot be checked out, so give it that README first.

If the variable is set but the App is not installed on the repository, the job fails at the token step
after the release is already published: install the App and re-run that job. A release that went out
before the variables were set can be copied by hand from its `fsp.rb` and `fsp.json` assets. Unset, the
job is skipped.

**By hand, per release** (the editor plugins are versioned on their own and not part of the release
PR):

- **JetBrains Marketplace (IntelliJ plugin).** Build the plugin from the tag with
  `cd editors/intellij && ./gradlew buildPlugin` (JDK 21) and upload
  `build/distributions/fespalier-intellij-<version>.zip` on the plugin's page in the
  JetBrains Marketplace, or run `PUBLISH_TOKEN=<token> ./gradlew publishPlugin`. Bump
  `version` in `editors/intellij/build.gradle.kts` first. The first upload needs a vendor
  account and a manual review; later ones can use a permanent token from the Marketplace's
  _My Tokens_ page.
- **VS Code extension.** Not published to a marketplace: build the `.vsix` from source (see
  `editors/vscode/README.md`). Bump `version` in `editors/vscode/package.json` first if you
  distribute a build.
