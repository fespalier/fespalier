# The download model

Since 0.15.0, `package:fespalier_download/fespalier_download.dart`. Read the files in
`packages/fespalier_download/lib/src/` for the exact signatures; this page keeps the rules an agent gets wrong.

## Locations

```dart
const file = DownloadLocation(DownloadBase.support, 'manuals/manual-42.pdf');
file.isValid; // true
```

`DownloadBase` is `support` (private to the app, the default), `cache` (the platform may delete it) or `documents`.
`isValid` is false for:

| Path                            | Why                   |
| ------------------------------- | --------------------- |
| `''`                            | empty                 |
| `/x`                            | leading `/`: absolute |
| `a//b`, `a/`                    | an empty segment      |
| `..`, `../x`, `a/../x`, `a/..`  | a `..` segment        |
| `a\b`, `..\x`                   | a backslash           |
| `a` followed by a NUL, then `b` | a NUL character       |

A name such as `.hidden` or `a..b` is valid: only a whole segment equal to `..` is refused. Locations are equal by base and
path, and `toString()` prints the base only.

## Requests

```dart
final request = DownloadRequest(
  id: 'manual-42',
  url: Uri.parse('https://files.example.com/manual-42.pdf'),
  file: file,
  bytes: 1048576,
  sha256: '…64 hex digits…',
  network: DownloadNetwork.unmetered,
  priority: DownloadPriority.userInitiated,
);
```

`isValid` is false for: an empty `id`; a URL whose scheme is not `http` or `https`, with no host, or with credentials
(`https://user:pass@host/`); an invalid `file`; a negative `bytes`; a `sha256` that is not exactly 64 hexadecimal digits
(upper or lower case); a header with an empty or blank name. `bytes: 0` is valid.

`headers` are request headers and **may be stored in plaintext by a backend**. `displayName` is for a notification and is
never reported to telemetry. `toString()` is the constant `DownloadRequest`.

## Status

`Absent`, `Queued`, `Waiting(WaitReason)`, `Running(received, [total])`, `Paused(received, [total])`, `Verifying`,
`Complete(file, bytes)`, `Failed(DownloadFailure)` and `Cancelled`, a sealed family with value equality. A `toString()`
prints the state and the numbers (`Running(5/10)`, `Running(5/?)`, `Failed(hashMismatch)`) and never a path.

`WaitReason`: `network`, `unmetered`, `retry`, `slot`.

`DownloadFailure`: `unsupported`, `invalidRequest`, `network`, `rejected`, `unauthorized`, `sizeMismatch`, `hashMismatch`,
`storage`, `notificationsRequired`, `killed`, `other`. The names are what telemetry reports as `fespalier.download.failure`.

## Ports

- `DownloadBackend`: `capabilities`, `open(events)`, `close()`, `enqueue(request, authorization:)`, `pause(id)`,
  `resume(id, authorization:)`, `cancel(id)`, `cancelAll()`, `resolve(location)` and
  `configureNotifications(notifications)`. A refusal is a `false` or a status event, never an exception the caller must
  read. `authorization` is extra headers for one attempt and is never stored.
- `DownloadCapabilities`: `pause`, `resumeAcrossRestart`, `background`, `userInitiated`, `unmetered`, `notifications`,
  all false until a backend says otherwise.
- `DownloadEvents`: `status(id, status, {httpStatus})` and `tapped(id, kind)` (`DownloadTapKind.body` or `action`).
- `DownloadStore`: `load`, `put`, `remove`, `clear` over `StoredDownload` (the request and a generation counter).
- `DownloadFiles`: `exists`, `length`, `delete` for a `DownloadLocation`.

## Telemetry

`FespalierDownloadConventions`: `transfer` (`fespalier.download.transfer`) with `resumed`, `background`, `network` and
`priority` at the start and `result` (`complete`, `failed`, `cancelled`) and `failure` at the end; `reconciled`; and `open`
with `routed`. All are `TelemetryOp.custom` operations. This release defines the names and nothing reports them yet.
