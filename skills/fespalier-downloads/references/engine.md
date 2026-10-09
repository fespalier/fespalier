# The Downloads engine

Since 0.15.0, `package:fespalier_download/fespalier_download.dart`. Pure Dart: no Riverpod, no timer, no listener. The
guide is [docs/downloads.md](../../../docs/downloads.md).

```dart
final downloads = Downloads(backend: backend, store: store, files: files);
await downloads.open();
downloads.observe((id, status) {}); // one owner; a second call replaces it
await downloads.start(request);
```

## Commands

| Call             | Does                                                                                                                  |
| ---------------- | --------------------------------------------------------------------------------------------------------------------- |
| `start(request)` | Registers and enqueues. Invalid request or location: `Failed(invalidRequest)`, not registered. Same active id: no-op. |
| `pause(id)`      | Asks the backend; true when it took the request. The status moves when the backend reports `Paused`.                  |
| `resume(id)`     | Only from `Paused`; true when taken, and the status is `Queued` until the backend reports.                            |
| `retry(id)`      | Only from `Failed` with a registered request; a size or digest mismatch deletes the file first.                       |
| `cancel(id)`     | Stops for good, drops the registry entry, deletes the partial: `Cancelled`. A `Complete` download is left alone.      |
| `remove(id)`     | Cancels, deletes the file and the entry: `Absent`.                                                                    |
| `pathOf(id)`     | The backend's resolved path for a `Complete` download, otherwise null. Never store it.                                |
| `clearAccount()` | Sign-out: cancel all, delete files and registry, every id `Absent`, later events dropped.                             |

`statuses` is a copy of the whole state; `statusOf(id)` is `Absent` for an unknown id.

## Generations

Each id has a generation moved on by cancel, remove, restart (`start` or `retry`) and `clearAccount`. After an `await`
the engine checks it and drops what is stale, so a cancel during a slow `enqueue` stays cancelled. An event for an id that
is not in the registry, or that has ended, is dropped. The engine cannot tell a late report of an old attempt from the
new one once the same id was started again: a backend must not report on a transfer it was told to cancel.

## After a restart

`open()` loads the registry (each entry `Queued`), opens the backend and takes its replay: finished or failed entries end
`Complete` or `Failed` and are reported as `fespalier.download.reconciled`; running ones go on with a `resumed` transfer
span; an entry nobody mentions ends `Complete` if `DownloadFiles` finds its file (and the size, when the request names one)
and `Failed(killed)` otherwise. Test it with `FakeDownloadBackend(replay: {...})` over a `MemoryDownloadStore` that already
holds the entries.

The registry in an app is `FileDownloadStore` (since 0.15.0), a JSON file written by atomic rename that never evicts; the
providers are in [`SKILL.md`](../SKILL.md#in-a-widget).

## Telemetry

One `fespalier.download.transfer` span per attempt, ended by the state it reaches (`result` and `failure`), and
`fespalier.download.reconciled` for what ended while the app was away. Constants, booleans and enum names only. A test that
records the sink and checks every string against `FespalierDownloadConventions` is the pattern in
`packages/fespalier_download/test/engine_test.dart`.

## Grants (since 0.15.0)

`Downloads(grantor:)` takes a `DownloadGrantor`, `FutureOr<DownloadGrant?> Function(DownloadRequest, {required bool renewal})`.
The engine calls it with `renewal: false` before the backend sees a start, a retry or a resume (a resume uses only the grant's
headers), and with `renewal: true` once per attempt chain when a backend reports a failure with HTTP status 401 or 403 (never
while reconciling at `open()`). The renewal moves the id's generation on, shows `Queued`, waits for the grant, then
`backend.cancel(id)` and `backend.enqueue(grantedRequest, authorization: grant.headers)`. A second 401 or 403 is
`Failed(unauthorized)`, as is a throwing grantor or a grant whose URL makes an invalid request. Every wait is
guarded by the generation, so a cancel, remove, restart or `clearAccount()` meanwhile means the answer is dropped.
`start`, `retry` and a renewal reset nothing in the registry: it holds the request as the app made it, never the grant.
