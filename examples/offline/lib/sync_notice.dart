import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// The report of the last sync an action started. `autoSync` keeps the reports of its own syncs (start,
/// resume, reconnect, tick); a sync an action starts after saving is not one of them, and its report is
/// where the person learns that the server undid an edit.
final lastSync = NotifierProvider<LastSync, SyncReport?>(LastSync.new);

/// The state of [lastSync].
class LastSync extends Notifier<SyncReport?> {
  @override
  SyncReport? build() => null;

  /// Keeps [report], unless the container is gone by the time the sync answers.
  void record(SyncReport report) {
    if (ref.mounted) state = report;
  }
}

/// Save locally, then sync best-effort: the person never waits for the network to save. A sync never
/// throws; it reports what failed, and the triggers try again.
void syncSoon(Ref ref) {
  final notice = ref.read(lastSync.notifier);
  ref.read(syncEngine).sync(SyncReason.manual).then(notice.record);
}
