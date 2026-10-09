---
name: fespalier-downloads
description: "Files downloaded in a fespalier app with fespalier_download (since 0.15.0) — the model, ports, the Downloads engine and the foreground HttpDownloadBackend: Downloads (open, start, pause, resume, retry, cancel, remove, pathOf, statusOf, observe, clearAccount, reconciliation after a restart), DownloadRequest (id, URL, a DownloadLocation of a DownloadBase and a relative path, headers, size, sha256, DownloadNetwork, DownloadPriority) and its isValid, DownloadLocation.isValid refusing an absolute path, .., a backslash and NUL, the sealed DownloadStatus family (Absent, Queued, Waiting, Running, Paused, Verifying, Complete, Failed, Cancelled) with WaitReason and DownloadFailure, the DownloadBackend, DownloadStore and DownloadFiles ports, the fespalier.download telemetry that never carries a URL, an id or a path, HttpDownloadBackend (Range and If-Range resume from a .part file, size and sha256 checks, pause only, the web ends unsupported), TransferDownloadFiles, and FakeDownloadBackend, MemoryDownloadStore, FakeDownloadFiles and FakeTransferFiles in tests. Load before adding a file download, an offline file, a progress screen or a resumable transfer, or when a request is not valid, a path is refused, or a test needs a download with no network."
---

# fespalier-downloads

> **Verified against fespalier `ca214107` (2026-10-09), release v0.14.0.**
> These skills ship in the fespalier repository, and CI checks them against its code
> on every change. Version-sensitive claims say the release they became true in; if
> your app pins another fespalier, trust that release's code over this page. See
> [Versions](https://github.com/fespalier/fespalier/blob/main/skills/README.md#versions).

**Since 0.15.0.** `package:fespalier_download` is the vocabulary of a download that outlives a screen: a request, a status
and the ports of a transfer engine. It adds no file kind, no `fespalier:` key and no `fsp` command, and `app.g.dart` is the
same bytes. It is pure Dart over `package:http`, with no platform plugin, and resolves on Flutter 3.32. A release that
predates 0.15.0 has no such package.

**Not built yet in this release: providers, a background backend and notification taps.** The engine, `Downloads`, and the
foreground `HttpDownloadBackend` exist (since 0.15.0); do not write `downloads` or `downloadStatus` provider code, or a
background backend: they do not exist. A download that must go on while the app is closed is not possible yet.

## The foreground backend

`HttpDownloadBackend(client: client, bases: bases)` (since 0.15.0) downloads with the app's `http.Client` while the app runs.
`bases` is a `Future<String> Function(DownloadBase)` the app writes (usually `path_provider`); give the engine
`TransferDownloadFiles(bases: bases)` so `remove`, `cancel` and sign-out delete the file and its `.part` and `.part.etag`.

- **Capabilities are `pause` only.** No background, no notifications, no user-initiated priority. A request with
  `DownloadNetwork.unmetered` is refused (`Failed(other)`), because the foreground cannot tell a metered network.
- **Resume is by bytes on disk**: the next attempt sends `Range` and `If-Range` from the `.part` and its validator; a
  server that ignores them restarts from byte 0; a part with no validator and no `sha256` restarts. After an app restart
  the engine reports `Failed(killed)`, and `retry` continues from the part.
- **A file at the destination is whole and checked** (size, then SHA-256 in another isolate, then an atomic move). A
  mismatch deletes the part. `cancel` deletes the part of a transfer in progress; an ended one keeps it for `retry`.
- **Failures**: `network`, `rejected` (other HTTP errors), `unauthorized` (401, 403), `sizeMismatch`, `hashMismatch`,
  `storage`, `unsupported`. On the web every start is `Failed(unsupported)` before a request: hand the browser the URL.
- **The client must honour `http.Abortable`** (the `package:http` clients do) or a pause cannot free a silent connection.
- `HttpTransfer` and `TransferFiles` are the pieces under it, exported for a backend of your own.

## Install

```yaml
# pubspec.yaml: the same url and the same ref as fespalier, or pub refuses to resolve
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: <the tag of your fespalier>
  fespalier_download:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_download
      ref: <the same tag>
```

(A fragment: pub resolves the pair only at a release tag that contains the package, 0.15.0 or later. Write `ref: v…` with
a real tag in an app, but never in these pages, where `cli/tests/versions.rs` would read it as fespalier's own version.)

## The shape of it

| You import                                           | For                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `package:fespalier_download/fespalier_download.dart` | `DownloadRequest`, `DownloadLocation`, `DownloadBase`, `DownloadNetwork`, `DownloadPriority`, `DownloadStatus` and its cases, `WaitReason`, `DownloadFailure`, the ports `DownloadBackend`, `DownloadEvents`, `DownloadCapabilities`, `DownloadStore`, `DownloadFiles`, `Downloads`, `DownloadObserver`, `HttpDownloadBackend`, `DownloadBases`, `TransferDownloadFiles`, `HttpTransfer`, `TransferFiles`, `FespalierDownloadConventions` |
| `package:fespalier_download/testing.dart`            | `FakeDownloadBackend` (with `replay:`), `MemoryDownloadStore`, `FakeDownloadFiles`, `FakeTransferFiles`                                                                                                                                                                                                                                                                                                                                   |

The engine in detail, with the restart and sign-out rules, is [`references/engine.md`](references/engine.md). The model in detail, with the exact refusals of `isValid`, is [`references/model.md`](references/model.md). The fakes and a
test that plays a platform are [`references/fakes.md`](references/fakes.md).

## Golden rules

- **A file is a `DownloadBase` and a relative path, never an absolute path.** An iOS app's container path changes between
  launches, so a stored absolute path goes stale. The default base is `support`. A path that came from outside the app
  (a server's file name) goes through `DownloadLocation.isValid` first.
- **Check `isValid` before you start anything.** A request with a `file://` URL, credentials in the URL, a short digest or
  a `..` in its path is `invalidRequest`, not a download.
- **A request's `toString()` prints no field.** Do not add a `toString` of your own that does, and do not log
  `request.url`: the URL can be a capability.
- **No long-lived credential in `headers`.** A backend may keep them on disk in plaintext while a download is queued. The
  documented path is a short-lived capability: make the normal signed request in the foreground, get a short-lived URL back,
  and put that in the request. Never a refresh token, never a long-lived bearer.
- **The registry is never a cache.** A `DownloadStore` keeps what the app asked for until `remove` or `clear` (sign-out);
  it must not be a `BoundedDataStorage`, which evicts.
- **Telemetry names are the contract**, `fespalier.download.transfer`, `.reconciled` and `.open`: add, never rename. Their
  values are constants, booleans and enum names, never a URL, an id, a path, a display name, a header or an error's text.
  If you add a span of your own, keep those out of it too.

- **`Downloads` imports no Riverpod and is yours to own** (since 0.15.0): `open()` it before `start`, give `observe` one
  owner, `close()` it when that owner goes, and call `clearAccount()` at sign-out.
- **`start` never throws for a bad request**: an invalid request or location is `Failed(invalidRequest)`, a
  `userInitiated` request with no notifications on the backend is `Failed(notificationsRequired)`. Neither is registered,
  so `retry` does nothing for them: fix the request and `start` again.

## Traps

- **`Failed(DownloadFailure)` carries a value, not a message.** There is no error text to show; map each failure to your
  own copy. `unauthorized` (401 or 403) is the one a later engine will answer by asking for a fresh grant.
- **A restart settles the registry once, at `open()`.** Give the engine a `DownloadFiles` unless the backend replays
  finished downloads: an entry nobody mentions is `Failed(killed)` without one.
- **`Running.total` is null when the server did not say**: do not divide by it without a check.
- **A switch over `DownloadStatus` is exhaustive** (it is sealed): a new case in a later release is a compile error in your
  `switch`, which is the point.
- **The web cannot download this way**: the foreground backend ends every start there as `Failed(DownloadFailure.unsupported)`;
  hand the browser the URL instead.
- **The package never asks for notification permission**, now or later. The app does.
