import 'package:fespalier/fespalier.dart';
import 'package:fespalier_download/fespalier_download.dart';

import 'uploads.dart';

/// The app's upload engine (since 0.15.0). It has no default: the app's `startup.dart` overrides it
/// with an `Uploads` over `BackgroundUploaderBackend` and a `FileUploadStore`; a test overrides it
/// with `uploadTestOverrides`. The [uploads] notifier opens the engine and closes it.
final uploadsEngine = Provider<Uploads>(
  (ref) => throw StateError(
    'uploadsEngine: no Uploads. Override it in startup.dart with '
    'uploadsEngine.overrideWithValue(Uploads(backend: ..., '
    'store: FileUploadStore(...))), or in a test with uploadTestOverrides.',
  ),
);

/// The status of every upload, by id (since 0.15.0): `ref.watch(uploads)`. Watching it opens the
/// engine (settling what a restart left, see `Uploads.open`) and fills the engine's one observer
/// slot; disposing it clears the observer and closes the engine (the transfers the platform owns go
/// on). To act, `ref.read(uploadsEngine).start(...)`.
final uploads = NotifierProvider<UploadsNotifier, Map<String, DownloadStatus>>(
  UploadsNotifier.new,
);

/// The notifier behind [uploads].
class UploadsNotifier extends Notifier<Map<String, DownloadStatus>> {
  @override
  Map<String, DownloadStatus> build() {
    final engine = ref.watch(uploadsEngine);
    engine.observe((id, status) {
      if (ref.mounted) state = engine.statuses;
    });
    ref.onDispose(() {
      engine.observe(null);
      engine.close().then<void>((_) {}, onError: (Object _) {});
    });
    engine.open().then<void>((_) {
      if (ref.mounted) state = engine.statuses;
    }, onError: (Object _) {});
    return engine.statuses;
  }
}

/// Where the upload [id] stands (since 0.15.0), [Absent] when none is known. Rebuilds a widget
/// only when this upload changes.
final uploadStatus = Provider.autoDispose.family<DownloadStatus, String>(
  (ref, id) => ref.watch(uploads.select((all) => all[id] ?? const Absent())),
);
