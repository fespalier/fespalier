// A store that throws is an AsyncError the screen reads, not a reason to ask again: Riverpod 3's
// default retry would re-read it up to ten times (about 50 seconds) with a Timer, which
// fespalier_cratestack never starts.
import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// A store on a plugin that is gone: every read of the keys throws an `Exception`.
final class _FailingStore implements LocalStore {
  int asked = 0;

  @override
  Future<Iterable<String>> keys(String prefix) async {
    asked++;
    throw Exception('the store is gone');
  }

  @override
  String? read(String key) => null;

  @override
  void write(String key, String value) {}

  @override
  void writeAll(Map<String, String> entries) {}

  @override
  void delete(String key) {}

  @override
  void clear(String prefix) {}
}

void main() {
  test(
    'pendingIntents on a store that throws is asked once, with no timer',
    () {
      fakeAsync((async) {
        final store = _FailingStore();
        final container = ProviderContainer(
          overrides: crateStackTestOverrides(store: store, scope: 'u1'),
        );
        final held = container.listen(pendingIntents(null), (_, _) {});
        async.flushMicrotasks();

        final state = container.read(pendingIntents(null));
        expect(state.hasError, isTrue);
        expect(state.isLoading, isFalse);
        expect(async.pendingTimers, isEmpty);
        // Riverpod's default would read again after 200 ms, 400 ms, 800 ms...
        async.elapse(const Duration(minutes: 2));
        expect(store.asked, 1);
        expect(async.pendingTimers, isEmpty);

        held.close();
        container.dispose();
      });
    },
  );
}
