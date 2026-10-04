// The two lines `fespalier_sentry` prints, word for word (the troubleshooting skill quotes them),
// and when. Both are about `tracing: true`: the default, errors first, asks nothing of the SDK's
// tracing and so has nothing to complain about.
import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'support.dart';

const String streamMessage =
    "fespalier_sentry: Sentry's traceLifecycle is stream, which this version "
    'makes no spans for. Errors and breadcrumbs are still sent; use '
    'SentryTraceLifecycle.static for screen transactions.';

const String noSamplingMessage =
    'fespalier_sentry: tracing: true needs Sentry to sample transactions, and '
    'tracesSampleRate is not set, so no transaction is sent. Pass tracing: true '
    'to FespalierSentry.configure, or set options.tracesSampleRate.';

/// What [body] printed with `debugPrint`. The override is put back before the test body ends:
/// the test binding refuses a test that leaves a foundation debug variable changed.
Future<List<String?>> printing(Future<void> Function() body) async {
  final printed = <String?>[];
  final original = debugPrint;
  debugPrint = (message, {wrapWidth}) => printed.add(message);
  try {
    await body();
  } finally {
    debugPrint = original;
  }
  return printed;
}

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  testWidgets('tracing: true on an SDK that samples nothing says so, once', (
    tester,
  ) async {
    final rig = Rig(
      tracing: true,
      configured: false,
      configure: (o) => o.tracesSampleRate = null,
    );
    final printed = await printing(() async {
      final r = await rig.boot(tester);
      r.go('/other');
      await tester.pumpAndSettle();
      r.go('/items/7');
      await tester.pumpAndSettle();
    });
    expect(printed, [noSamplingMessage]);
    // No transaction, and the rest is untouched: the route names the scope.
    expect(await rig.lines(tester), isEmpty);
    expect(rig.sentry.tags['fespalier.route'], '/items/:id');
  });

  testWidgets('tracing: true on a streaming SDK says so, once, and sends the '
      'errors and breadcrumbs all the same', (tester) async {
    load = (_) => Future<String>.error(StateError('no such item'));
    final rig = Rig(
      tracing: true,
      configure: (o) => o.traceLifecycle = SentryTraceLifecycle.stream,
    );
    final printed = await printing(() async {
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      r.go('/other');
      await tester.pumpAndSettle();
    });
    expect(printed, [streamMessage]);
    expect(await rig.lines(tester), [
      r'event StateError operation=data route=/items/:id file=items/$id/data.dart',
    ]);
    expect(rig.sentry.breadcrumbs, contains('navigation enter /other'));
  });

  testWidgets('the default prints nothing, whatever the SDK is set to', (
    tester,
  ) async {
    final rig = Rig(
      configure: (o) => o.traceLifecycle = SentryTraceLifecycle.stream,
    );
    final printed = await printing(() async {
      final r = await rig.boot(tester);
      r.go('/other');
      await tester.pumpAndSettle();
    });
    expect(printed, isEmpty);
  });

  testWidgets('tracing: true on an SDK that traces prints nothing', (
    tester,
  ) async {
    final rig = Rig(tracing: true);
    final printed = await printing(() async {
      final r = await rig.boot(tester);
      r.go('/other');
      await tester.pumpAndSettle();
    });
    expect(printed, isEmpty);
  });
}
