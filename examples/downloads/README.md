# downloads

Downloads with [`fespalier_download`](../../packages/fespalier_download): a list of downloads, each with the buttons that
make sense for where it stands (start, pause, resume, retry, cancel, remove), a detail page that a tap on a download's
notification opens, and a sign-out that wipes everything. The skill is
[`fespalier-downloads`](../../skills/fespalier-downloads/SKILL.md) and the guide is [Downloads](../../docs/downloads.md).

This README has two audiences. [Test it on a device](#test-it-on-a-device) is for someone who wants to try the
downloads on a phone or a desktop and **needs no knowledge of fespalier and writes no code**. [How it is built](#how-it-is-built)
is for a developer.

## Test it on a device

This is the manual test of issue
[#157](https://github.com/fespalier/fespalier/issues/157): download real files over a real network, on at least one
Android phone or iPhone and one desktop (macOS, Windows or Linux), and report what happened.

### What you need

- [Flutter](https://docs.flutter.dev/get-started/install) (the version in `FLUTTER_VERSION` of
  [`ci.yml`](../../.github/workflows/ci.yml), 3.47.5 when this was written), and the platform tools of the device you test on
  (Android Studio or Xcode).
- A clone of this repository, on the commit you were asked to test.
- Wi-Fi, and about 300 MB free on the device.

### Run it

```sh
cd examples/downloads
flutter create . --platforms=android,ios,macos,linux,windows,web   # adds the platform folders only; keep the ones you test on
flutter pub get
```

The example commits no platform folders, as the other examples do. Then do **the one setup step of your platform**:

- **Android:** add `<uses-permission android:name="android.permission.INTERNET" />` inside `<manifest>` in
  `android/app/src/main/AndroidManifest.xml` (a debug build has it already; a profile or release build does not).
- **macOS:** make sure `macos/Runner/DebugProfile.entitlements` **and** `macos/Runner/Release.entitlements` contain
  `<key>com.apple.security.network.client</key><true/>`. Without it every download fails as `network`.
- **iOS, Linux, Windows, web:** nothing.

Then run it on a device (`flutter devices` lists them):

```sh
flutter run -d <device id>
```

For the **kill** case below use a **profile or release** build, because killing a debug build ends the debug session and
on iOS a debug build cannot be reopened from the home screen: `flutter run --profile -d <device id>` (Android needs the
`INTERNET` line above for this).

You see one card per case. Each card shows where its download stands and **only the buttons that make sense** for that
state. **Details** opens the page of that download, which is the page to copy into your report: it shows the status, the
size and SHA-256 the file must have, the file at the destination, the partial file (`.part`) the transfer keeps, and, once
the download is `Complete`, where the file is on the device. **Refresh the files** reads the disk again (it also reads it
whenever the kind of status changes).

### The files

By default the app downloads two public files of Alpine Linux 3.22.0, a stable release that stays on the mirror
(`dl-cdn.alpinelinux.org`, which supports `Range` requests, so a download can resume):

- **Large file** (`alpine-standard-3.22.0-x86_64.iso`): 281018368 bytes, SHA-256
  `08283b76f95c0828f51c03ade5690eb4a4bda8e1c86f57567ae8cedaf4f04aae`.
- **Small file** (`alpine-minirootfs-3.22.0-x86_64.tar.gz`): 3655173 bytes, SHA-256
  `18879884e35b0718f017a50ff85b5e6568279e97233fc42822229585feb2fa4d`.

Both digests are the ones Alpine publishes beside the files; the files were downloaded and hashed to check them.

The app compares the size and the SHA-256 itself and says `Complete` only when both are right.

To use **your own file** (a server that supports `Range`; say which one in your report), start the app with
`--dart-define`s. The digest is 64 hexadecimal digits (`sha256sum yourfile`), the size is in bytes:

```sh
flutter run -d <device id> \
  --dart-define=LARGE_URL=https://example.com/big.iso \
  --dart-define=LARGE_SHA256=<64 hex digits> \
  --dart-define=LARGE_BYTES=<size in bytes> \
  --dart-define=SMALL_URL=https://example.com/small.bin \
  --dart-define=SMALL_SHA256=<64 hex digits> \
  --dart-define=SMALL_BYTES=<size in bytes>
```

### The cases

Each case is a button. After each one, open **Details** and keep what it says for the report.

1. **A large file.** On the *Large file* card press **Start**. The progress bar moves and the byte count goes up. Wait
   for the end. *Expected:* `Complete: 268.0 MB, checked`; on **Details**, the file at the destination is `281018368
   bytes` and there is no partial file.
2. **Pause and resume.** Press **Start** on the *Large file* card (after **Remove** if it is complete), wait until about
   half is there, press **Pause**. *Expected:* `Paused: <bytes> of 268.0 MB`. Wait ten seconds, then press **Resume**.
   *Expected:* the byte count goes on from where it stopped and does **not** start over from zero.
3. **Airplane mode.** Start the *Large file*, switch airplane mode on (or turn Wi-Fi off) while it runs. *Expected:*
   `Failed (network)` after a moment and the app still works. **Details** shows a partial file. Switch the network on and
   press **Retry**. *Expected:* it goes on from the bytes already received (the count starts at the partial file's size,
   not at zero) and ends `Complete`.
4. **Kill the app.** Start the *Large file*, and while it runs close the app the hard way (Android: swipe it away from the
   recent apps; iOS: swipe it up; desktop: quit it, or `kill -9`). Open the app again. *Expected:* the card shows `Failed
   (killed)`, **Details** shows a partial file, and **Retry** goes on from the bytes on disk and ends `Complete`.
5. **A wrong checksum.** On the *Wrong checksum* card press **Start**. It downloads the small file but asks for a SHA-256
   of zeros. *Expected:* `Failed (hashMismatch)`; on **Details**, *File at the destination: none* and no partial file.
6. **Sign-out.** Have a few cards in different states (a `Complete` small file, a paused or failed large one), then press
   **Sign out (clear all)**. *Expected:* every card is `Not started`, and **Details** of each shows no file and no partial
   file. On a desktop you can check the folder that **Details** showed under *On this device*.
7. **The web.** Run `flutter run -d chrome` and press any **Start**. *Expected:* `Failed (unsupported)` at once, with no
   request made.

If the file you tested is `Complete` you can check it yourself on a desktop: `sha256sum <the path Details shows>` (or
`shasum -a 256`) prints the digest in the table above.

### What to report

Comment on the issue with, per device:

- the device, the OS version and the network (Wi-Fi or mobile);
- `flutter --version` and the commit you tested (`git rev-parse HEAD`);
- the file you used (the default, or your URL and the server);
- for each of the seven cases: what you pressed, what the card said, and what **Details** said (copy the text, it is
  selectable). Say if it was what the case expects or not.

If a download restarted from zero after **Resume** or **Retry**, say which server it came from: a server that ignores
`Range` cannot resume.

## How it is built

```text
lib/
  main.dart            configureDownloads(); AppMain.run()
  setup.dart           the configuration: HttpDownloadBackend + FileDownloadStore + TransferDownloadFiles, the grantor,
                       the tap-to-route mapping (a test passes fakes)
  cases.dart           the three cases, from --dart-define
  widgets.dart         status text, progress, and the buttons (one per engine action)
  app/
    app.dart           MaterialApp.router
    page.dart          /  the cards and the sign-out
    files/$id/page.dart /files/:id  the detail page
```

- `pubspec.yaml` has `fespalier: adapters: [fespalier_download]`. The generated `main()` then asks the adapter for the
  launch location, which **opens the engine before the first frame** and answers a notification tap that started the app;
  `attach` opens a tap that arrives later. The package is configured before that, in `main()`:
  `FespalierDownload.configure(backend:, store:, files:, grantor:, route:)` (see
  [`lib/setup.dart`](lib/setup.dart) and [Notification taps](../../docs/downloads.md#notification-taps)). The app has no
  `startup.dart`: the adapter binds `downloadsEngine`.
- The **foreground** `HttpDownloadBackend` runs the transfer in the app's process over `package:http`. It can pause and
  resume (HTTP `Range`) and it stops when the app is closed. It shows no notification, so on a phone nothing taps a
  notification here; the tests play the tap.
- `FileDownloadStore` is the registry, a JSON file in the support folder, so after a restart the engine knows what was
  asked and settles it (`Failed (killed)` for a download that was running). Folders come from `path_provider`
  (`bases` in `setup.dart`): the package has no plugin of its own.
- **The grantor is a demo.** A real app asks its server for a short-lived URL here, with its signed session
  ([Credentials](../../docs/downloads.md#credentials)). The demo has no server: `demoGrantor` adds a harmless
  `X-Demo-Grant` header and records that it was asked (the detail page counts them). No secret, no key and no
  token is in this app.
- To make the detail page open from a tap, `tapTarget` maps a `DownloadTap` to `FileRoute(id:)`; a tap on a download the
  account no longer has maps to nothing.

### Tests

```sh
flutter test
```

The tests boot `AppMain.root()` as `main()` does, with `FakeDownloadBackend`, `MemoryDownloadStore` and
`FakeDownloadFiles` in place of the network and the disk: no network is used. They check that the list shows what the
backend reports, that each button reaches the engine (`enqueued`, `paused`, `resumed`, `cancelled`), that a hash mismatch
shows as such, that a restart settles a running download as `Failed (killed)`, that sign-out calls `cancelAll` and clears
the registry, that a **cold start from a notification tap** opens `/files/large` (`replayTaps`), that a tap while the app
runs does too, and that a tap on an unknown download goes nowhere. What no test can see is the part this README is for: a
real network, a real disk and a real kill.

### The background backend

The example stays on the foreground backend, which runs on every Flutter the repository supports.
[`fespalier_download_background`](../../packages/fespalier_download_background) needs Flutter 3.47 and the platform setup of
[Android and iOS setup](../../docs/downloads.md#android-and-ios-setup). To try it, add it to `pubspec.yaml` (path
dependency, with `sdk: ^3.13.0`), do that setup, and in `configureDownloads` replace the backend with
`BackgroundDownloaderBackend(notifications: const DownloadNotifications(running: 'Downloading', complete: 'Done', failed: 'Failed'))`
and pass `DownloadNotifications` as `notifications:` to `FespalierDownload.configure`. A tap on the notification then opens
`/files/<id>`. Its cases (a download that goes on while the app is closed) are a later device ticket.
