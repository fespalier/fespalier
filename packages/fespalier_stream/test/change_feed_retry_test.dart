// The feed's stream is opened once per container (a stream of flutter_rust_bridge is
// single-subscription), and a failure is kept in `latest`. Riverpod 3's default retry would open it
// again after 200 ms, up to ten times, with a Timer, which the package never starts.
import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final broadcast in [true, false]) {
    test(
      'a stream error is kept in latest, ${broadcast ? 'broadcast' : 'single-subscription'}: '
      'opened once, no timer',
      () {
        fakeAsync((async) {
          final core = FakeChangeSource<int>(broadcast: broadcast);
          var opened = 0;
          final feed = ChangeFeed<int>((ref) {
            opened++;
            return core.stream;
          });
          final container = ProviderContainer();
          final held = container.listen(feed.latest, (_, _) {});
          async.flushMicrotasks();
          core.emitError(StateError('core stopped'));
          async.flushMicrotasks();

          final state = container.read(feed.latest);
          expect(state.hasError, isTrue);
          expect(state.isLoading, isFalse);
          expect(async.pendingTimers, isEmpty);
          async.elapse(const Duration(minutes: 2));
          expect(opened, 1);
          expect(core.listenCount, 1);
          expect(async.pendingTimers, isEmpty);

          held.close();
          container.dispose();
        });
      },
    );
  }

  test(
    'a core that cannot open its stream is an error, asked once, no timer',
    () {
      fakeAsync((async) {
        var opened = 0;
        final feed = ChangeFeed<int>((ref) {
          opened++;
          throw Exception('the core is not started');
        });
        final container = ProviderContainer();
        final held = container.listen(feed.latest, (_, _) {});
        async.flushMicrotasks();

        final state = container.read(feed.latest);
        expect(state.hasError, isTrue);
        expect(state.isLoading, isFalse);
        expect(async.pendingTimers, isEmpty);
        // Riverpod's default would call open again after 200 ms, 400 ms, 800 ms...
        async.elapse(const Duration(minutes: 2));
        expect(opened, 1);
        expect(async.pendingTimers, isEmpty);

        held.close();
        container.dispose();
      });
    },
  );
}
