# Uploads

Since 0.15.0, in `package:fespalier_download_background` (read at `background_downloader` 9.6.4's `UploadTask`; it needs
Flutter 3.47). A release that predates 0.15.0 has no uploads. **Background only**: there is no foreground upload backend, and
on the web every upload ends `Failed(unsupported)`.

```dart
final uploads = Uploads(
  backend: BackgroundUploaderBackend(),
  store: FileUploadStore(bases: bases),
  grantor: grantUploadUrl, // optional
);
await uploads.open();
await uploads.start(
  UploadRequest(
    id: 'receipt-7',
    url: Uri.parse('https://api.example.com/receipts'),
    file: const DownloadLocation(DownloadBase.documents, 'outbox/receipt-7.jpg'),
    fileField: 'receipt',
    fields: {'orderId': '7'},
    headers: {'Idempotency-Key': 'receipt-7'},
  ),
);
```

Override `uploadsEngine` with it in `startup.dart`; `ref.watch(uploads)` and `ref.watch(uploadStatus(id))` are the widget side,
as `downloads` and `downloadStatus` are.

## Why a sibling engine

`Uploads` is not a mode of `Downloads`. A download whose file is whole is complete; an upload whose file is still there has
told you nothing about the server. So `Uploads` has **no file port**: `remove`, `cancel` and `clearAccount()` never delete the
file you sent, and after a restart an entry nobody mentions is `Failed(killed)`, **never `Complete`**. It keeps the engine's
guarantees: a generation per id, a never-evicted registry (`FileUploadStore`, `fespalier_uploads.json`, not a
`BoundedDataStorage`), one `observe` slot, `clearAccount()`, no Riverpod in the engine.

## The request

`UploadRequest(id, url, file, method, encoding, fileField, fields, headers, network, priority, displayName)`. `file` is a
`DownloadLocation` (base and relative path, the download's validation, never absolute). `method` is `UploadMethod.post` (the
default) or `put`. `encoding` is `UploadEncoding.multipart` (the default; `fileField`, string `fields`) or `binary` (the file
is the whole body; `fields` must be empty). `isValid` checks it all; `toString()` prints no field. Statuses are
`DownloadStatus`: `Queued`, `Waiting`, `Running(sent, total)`, `Complete(file, bytes)` (the file sent, untouched) or
`Failed`. Never `Paused` or `Verifying`; the response body is not reported.

## Replay safety (a rule, pinned by tests)

`UploadRequest.replaySafe` is `!HttpWrites.isWrite(method, headers)`: an `Idempotency-Key` header makes an upload safe to send
again, anything else is a write the server may already have.

| Situation                                 | Replay safe                              | Not replay safe                                                 |
| ----------------------------------------- | ---------------------------------------- | --------------------------------------------------------------- |
| The platform retries after a failure      | `BackgroundOptions(retries:)`            | None: the task is made with `retries: 0`                        |
| Pause and resume                          | The plugin cannot pause an upload        | The same, so no pause cycle can send it twice                   |
| 401 or 403                                | One renewed grant, then sent again       | `Failed(unauthorized)`, no renewal                              |
| The app was killed, or no answer came     | `Failed(killed)`; `retry` sends it again | `Failed(killed)`; `retry` and `start` refuse                    |
| The response was lost (`Failed(network)`) | `retry` sends it again                   | The same: the server may have it (`outcomeUnknown(id)` is true) |

For a non-replay-safe upload, `Failed(network)`, `Failed(killed)` and `Failed(other)` mean the outcome is unknown:
`Uploads.outcomeUnknown(id)` is true, `retry(id)` returns false and `start` of the id does nothing. Ask the server, then
`remove(id)` and `start` again if the app decides to. A server answer (`rejected`, `unauthorized`) or a failure before
anything was sent (`storage`, `invalidRequest`) may be retried. A pre-signed `PUT` is a write by this rule too: add an
`Idempotency-Key` header when sending it again is harmless. **Never "fix" a stuck non-replay-safe upload by re-sending it
from the engine or the backend.**

## Rules

- **Auth is a grant**: `Uploads(grantor:)` returns a `DownloadGrant` (a short-lived pre-signed `url`, and/or headers for one
  attempt). Headers sit in plaintext in the OS task queue until the task ends. Never a refresh token or a long-lived bearer.
  The registry stores the request, never the grant.
- **Its own plugin group**, `fespalier.upload` (the downloads' is `fespalier.download`), so the two engines' callbacks never see
  each other's updates. Same rules as the downloads' backend: callbacks, tracking and notifications for the group only,
  registered before `resumeFromBackground`; never the app's `updates` stream and never the plugin's global `start`, `reset`,
  `configure` or `rescheduleKilledTasks`. `PluginUploadTransport` lives in `plugin_transport.dart`, the one file that calls
  the plugin (the no_timers test has no new exception).
- **Notifications are off unless configured**; `userInitiated` (priority 0, a user-initiated job on Android 14+) without a
  `running` text is `Failed(notificationsRequired)`. The package never asks for the notification permission.
- **Telemetry**: `fespalier.upload.transfer` (start: `background`, `network`, `priority`, `encoding`, `replay_safe`; end:
  `result`, `failure`, `regranted` only when true) and `fespalier.upload.reconciled`, `FespalierUploadConventions`. Constants,
  booleans and enum names; never a URL, id, path, field, header or error text. A rename is a breaking release.

## Test it

`FakeUploadBackend` (`emit(id, status, httpStatus:)`, `replay:`), `MemoryUploadStore`, `uploadTestOverrides(backend:)` for the
providers, and `FakeUploadTransport` (plays the plugin's upload group) for the backend itself. `uploadTaskOf` is pure and
shows exactly what the plugin is handed.

## UNCHECKED (no device has answered)

Never write these as fact: that the system sends an upload with the app closed; how a server reads the plugin's multipart
body (field order, the file part's `Content-Type`, large files) and a binary upload's `Content-Disposition`; whether a
non-2xx answer reaches the app as the status the mapping reads; how long an Android upload may run before WorkManager's limit
(the plugin's source ends a timed-out upload as a connection failure), with and without a user-initiated job; whether
WorkManager or the plugin sends an upload again on its own beyond the task's `retries`; what is delivered when the downloads
engine and the uploads engine open one after the other (`resumeFromBackground` is global; a lost update is settled as
`Failed(killed)`, never as a second send); whether the platform setup has a step of its own for uploads.
