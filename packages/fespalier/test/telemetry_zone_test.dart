// A sink that gives `within`'s zone an error handler is refused at run time (since 0.9.0): a
// `Future` that fails in another error zone never reaches Riverpod, so the page would stay on its
// loading view. fespalier runs the body outside that zone and prints the mistake once. A file of
// its own because the line is printed once per isolate, and the first test below asserts that a
// zone of values alone prints nothing.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const TelemetrySite site = TelemetrySite('items/data.dart', route: '/items');

const Symbol _key = #zoneTestSpan;

/// A sink whose `within` runs the body in the zone [make] builds.
final class InZone extends FespalierTelemetry {
  InZone(this.make);

  final void Function(Object? Function() body) make;

  @override
  Object? start(TelemetryStart start) => 'token';

  @override
  void within(Object? token, Object? Function() body) => make(body);
}

/// A sink that sets a zone value and no handler.
final class Values extends FespalierTelemetry {
  @override
  Object? start(TelemetryStart start) => 'values';

  @override
  void within(Object? token, Object? Function() body) =>
      runZoned(body, zoneValues: {_key: 'span'});
}

/// A provider whose `data()` fails after an await.
FutureProvider<String> failing(List<Object?> zoneValues) =>
    FutureProvider.autoDispose<String>(
      (ref) => traceDataCall(ref, 'd1', null, () async {
        zoneValues.add(Zone.current[_key]);
        await Future<void>.delayed(Duration.zero);
        throw StateError('data failed');
      }, telemetry: site),
    );

void main() {
  tearDown(() => FespalierTelemetry.install(null));

  test('a zone of values only is not refused, and prints nothing', () async {
    FespalierTelemetry.install(Values());
    final seen = <Object?>[];
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final provider = failing(seen);
    final lines = <String>[];
    final old = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add('$message');
    try {
      c.listen(provider, (_, _) {});
      await expectLater(c.read(provider.future), throwsStateError);
    } finally {
      debugPrint = old;
    }
    expect(lines, isEmpty);
    expect(seen, ['span']);
  });

  test('a zone that guards errors is refused: the error reaches Riverpod, '
      'and the line is printed once', () async {
    final caught = <Object>[];
    FespalierTelemetry.install(
      InZone((body) => runZonedGuarded(body, (e, s) => caught.add(e))),
    );
    final seen = <Object?>[];
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final provider = failing(seen);
    final lines = <String>[];
    final old = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add('$message');
    try {
      c.listen(provider, (_, _) {});
      await expectLater(c.read(provider.future), throwsStateError);
      expect(c.read(provider), isA<AsyncError<String>>());
      // A second load through the same sink says nothing more.
      c.invalidate(provider);
      c.listen(provider, (_, _) {});
      await expectLater(c.read(provider.future), throwsStateError);
    } finally {
      debugPrint = old;
    }
    // The sink's handler never got an error that belongs to the app.
    expect(caught, isEmpty);
    expect(lines, [
      'fespalier telemetry: InZone.within changed the error zone, so data() '
          'and actions run outside it (use runZoned with zoneValues, not '
          'runZonedGuarded) (not shown again)',
    ]);
  });

  test('so is a zone specification with an error handler', () async {
    FespalierTelemetry.install(
      InZone(
        (body) => runZoned(
          body,
          zoneSpecification: ZoneSpecification(
            handleUncaughtError: (self, parent, zone, error, stack) {},
          ),
        ),
      ),
    );
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final provider = failing(<Object?>[]);
    c.listen(provider, (_, _) {});
    await expectLater(c.read(provider.future), throwsStateError);
  });

  test('inside a combine the others still wrap data()', () async {
    final seen = <Object?>[];
    FespalierTelemetry.install(
      FespalierTelemetry.combine([
        InZone((body) => runZonedGuarded(body, (e, s) {})),
        Values(),
      ]),
    );
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final provider = failing(seen);
    c.listen(provider, (_, _) {});
    await expectLater(c.read(provider.future), throwsStateError);
    // The refused zone is skipped, the next sink's values are in data().
    expect(seen, ['span']);
  });

  test('an action keeps its error too', () async {
    FespalierTelemetry.install(
      InZone((body) => runZonedGuarded(body, (e, s) {})),
    );
    final action = actionProvider<String, String>(
      (ref, input) async {
        await Future<void>.delayed(Duration.zero);
        throw StateError('action failed');
      },
      invalidates: () => const [],
      telemetry: const TelemetrySite('a/action.dart', route: '/a', name: 'go'),
    );
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await expectLater(
      c.read(action.notifier)('x') as Future<String>,
      throwsStateError,
    );
  });
}
