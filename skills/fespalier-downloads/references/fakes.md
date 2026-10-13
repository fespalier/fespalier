# Testing downloads with fakes

Since 0.15.0, `package:fespalier_download/testing.dart`. None of them needs a network, a platform channel or a disk.

## FakeDownloadBackend

A `DownloadBackend` that does nothing by itself. The test plays the platform:

```dart
final backend = FakeDownloadBackend(); // capabilities: pause only; accepts: true
await backend.open(listener); // a DownloadEvents: whatever should hear the platform
backend.emit('manual-42', const Running(512, 1024));
backend.emit('manual-42', const Failed(DownloadFailure.unauthorized), httpStatus: 403);
backend.tap('manual-42'); // DownloadTapKind.body
```

- `emit` and `tap` throw a `StateError` before `open` and after `close`.
- It records `enqueued` (the requests), `authorizations` (the extra headers of each `enqueue` and `resume`), `paused`,
  `resumed`, `cancelled`, `cancelAllCalls` and the last `notifications`.
- `accepts: false` makes `enqueue` and `resume` answer false. `capabilities` without `pause` makes `pause` and `resume`
  answer false.
- `FakeDownloadBackend(replay: {id: status})` reports those statuses to the listener inside `open`, as a backend that kept
  downloads while the app was closed would: the way to test `Downloads.open()` after a restart.
- `resolve(location)` answers `/fake/<base>/<path>`: a stand-in that is not stored anywhere.

## MemoryDownloadStore

A `DownloadStore` in a map: `entries` is the live map, `load()` returns a copy, `clearCalls` counts `clear()`. Pass a map
to the constructor to start from a registry that "survived a restart"; it is copied, not shared.

## FakeDownloadFiles

A `DownloadFiles` over `sizes`, a map from `DownloadLocation` to a byte count. `put(location, bytes)` makes a file appear as
a finished transfer would; `delete` is recorded in `deleted` and is not an error when there is no file.

## FakeTransferFiles

A `TransferFiles` (the path level a transfer writes through) in a map: `putBytes`, `putText`, `bytesOf`, `textOf`, `paths`,
`renames`, `hashes`. `failWrites`, `failRename` and `failDelete` make that call throw; `unsupported = true` is the web
(`isSupported` false, every call an `UnsupportedError`). Test `HttpDownloadBackend` with it and a `MockClient` from
`package:http/testing.dart` whose streamed response honours the request's `abortTrigger`.

## What a model test looks like

The model is plain values, so no widget or fake is needed:

```dart
test('a path that leaves the folder is refused', () {
  expect(const DownloadLocation(DownloadBase.support, '../x').isValid, isFalse);
});

test('a request prints nothing', () {
  final request = DownloadRequest(
    id: 'a',
    url: Uri.parse('https://example.com/x?token=SECRET'),
    file: const DownloadLocation(DownloadBase.support, 'x'),
  );
  expect('$request', isNot(contains('SECRET')));
});
```
