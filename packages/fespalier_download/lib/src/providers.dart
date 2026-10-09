import 'package:fespalier/fespalier.dart';

import 'engine.dart';
import 'status.dart';

/// The app's download engine (since 0.15.0). It has no default: the app's `startup.dart`
/// overrides it with a `Downloads` over the platform's backend and a `FileDownloadStore`; a
/// test overrides it with `downloadTestOverrides`.
///
/// The [downloads] notifier opens the engine and closes it, so build the engine once and
/// override this provider with the value.
final downloadsEngine = Provider<Downloads>(
  (ref) => throw StateError(
    'downloadsEngine: no Downloads. Override it in startup.dart with '
    'downloadsEngine.overrideWithValue(Downloads(backend: ..., '
    'store: FileDownloadStore(...))), or in a test with downloadTestOverrides.',
  ),
);

/// The status of every download, by id (since 0.15.0): `ref.watch(downloads)`.
///
/// Watching it opens the engine (settling what a restart left, see `Downloads.open`) and fills
/// the engine's one observer slot; when the provider is disposed the observer is cleared and the
/// engine is closed (the transfers the platform owns go on). It holds no timer and no listener
/// of its own.
///
/// To act, `ref.read(downloadsEngine).start(...)`; the engine reports back through here.
final downloads =
    NotifierProvider<DownloadsNotifier, Map<String, DownloadStatus>>(
      DownloadsNotifier.new,
    );

/// The notifier behind [downloads].
class DownloadsNotifier extends Notifier<Map<String, DownloadStatus>> {
  @override
  Map<String, DownloadStatus> build() {
    final engine = ref.watch(downloadsEngine);
    engine.observe((id, status) {
      if (ref.mounted) state = engine.statuses;
    });
    ref.onDispose(() {
      engine.observe(null);
      // A provider cannot await its dispose, and close() reports nothing.
      engine.close().then<void>((_) {}, onError: (Object _) {});
    });
    // An engine that cannot open (a store that threw) stays as it is: the map stays empty.
    engine.open().then<void>((_) {
      if (ref.mounted) state = engine.statuses;
    }, onError: (Object _) {});
    return engine.statuses;
  }
}

/// Where the download [id] stands (since 0.15.0), [Absent] when none is known. Rebuilds a
/// widget only when this download changes.
final downloadStatus = Provider.autoDispose.family<DownloadStatus, String>(
  (ref, id) => ref.watch(downloads.select((all) => all[id] ?? const Absent())),
);
