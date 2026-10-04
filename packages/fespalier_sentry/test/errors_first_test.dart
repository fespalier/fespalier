// The default: `FespalierSentry()` is errors first. Out of the box it sends no transaction (even on
// an SDK that samples), names the scope after the screen so that every later event, a crash
// included, says which screen it happened on, and leaves Sentry's own transactions alone.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Map<String, Object?> map(Object? value) =>
    Map<String, Object?>.from(value! as Map);

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  testWidgets('sends no transaction, though the SDK samples every one', (
    tester,
  ) async {
    final rig = Rig(configured: false);
    expect(rig.sentry.options.tracesSampleRate, 1.0);
    final r = await rig.boot(tester);
    r.go('/shop');
    await tester.pumpAndSettle();
    r.go('/items/7');
    await tester.pumpAndSettle();
    r.go('/nowhere');
    await tester.pumpAndSettle();
    expect(await rig.lines(tester), isEmpty);
  });

  testWidgets('names the scope after the screen: its transaction and its '
      'route tag', (tester) async {
    final rig = Rig();
    expect(rig.sentry.transactionName, isNull);
    final r = await rig.boot(tester);
    expect(rig.sentry.transactionName, '/home');
    expect(rig.sentry.tags['fespalier.route'], '/home');
    r.go('/items/7');
    await tester.pumpAndSettle();
    expect(rig.sentry.transactionName, '/items/:id');
    expect(rig.sentry.tags['fespalier.route'], '/items/:id');
  });

  testWidgets('a crash after a navigation says which screen it happened on', (
    tester,
  ) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    // What Sentry's own integrations do with an uncaught error: the event is theirs.
    await rig.sentry.hub.captureException(StateError('crash'));
    final event = (await rig.sent(tester)).single;
    expect(event['transaction'], '/items/:id');
    expect(map(event['tags']), containsPair('fespalier.route', '/items/:id'));
    // No operation was in progress: the tags of an operation are not there.
    expect(map(event['tags']).containsKey('fespalier.file'), isFalse);
    // The segment value is app data: it is nowhere.
    expect(event.toString(), isNot(contains('/items/7')));
  });

  testWidgets('a location that is no page names the scope so, and takes the '
      'route tag off', (tester) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    r.go('/nowhere');
    await tester.pumpAndSettle();
    expect(rig.sentry.transactionName, 'navigate (not found)');
    expect(rig.sentry.tags.containsKey('fespalier.route'), isFalse);
    expect(rig.sentry.breadcrumbs, contains('navigation not found'));
  });

  testWidgets('a pop names the scope after the page it reveals', (
    tester,
  ) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    unawaited(r.push<void>('/other'));
    await tester.pumpAndSettle();
    expect(rig.sentry.tags['fespalier.route'], '/other');
    r.pop();
    await tester.pumpAndSettle();
    expect(rig.sentry.tags['fespalier.route'], '/home');
    expect(rig.sentry.transactionName, '/home');
  });

  testWidgets('never renames a transaction that is Sentry\'s own', (
    tester,
  ) async {
    final rig = Rig(configured: false);
    // Sentry's app start (or its navigator observer) binds a `ui.load` of its own.
    final own = rig.sentry.hub.startTransaction(
      'root /',
      'ui.load',
      bindToScope: true,
    );
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    expect(rig.sentry.transactionName, 'root /');
    // The tag is the sink's: it names the screen on any event.
    expect(rig.sentry.tags['fespalier.route'], '/items/:id');
    await own.finish();
  });

  testWidgets('routeTag: false names nothing', (tester) async {
    final rig = Rig(routeTag: false);
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    expect(rig.sentry.transactionName, isNull);
    expect(rig.sentry.tags, isEmpty);
    // The page breadcrumbs are not the route tag's.
    expect(rig.sentry.breadcrumbs, contains('navigation enter /items/:id'));
  });

  testWidgets('a superseded navigation names nothing', (tester) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    checkout = () => Future<String?>.value();
    r.go('/checkout');
    r.go('/items/2');
    await tester.pumpAndSettle();
    expect(rig.sentry.tags['fespalier.route'], '/items/:id');
  });

  testWidgets('with no sink installed there is nothing of it on the scope', (
    tester,
  ) async {
    final rig = Rig();
    FespalierTelemetry.install(null);
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    expect(rig.sentry.tags, isEmpty);
    expect(rig.sentry.breadcrumbs, isEmpty);
  });
}
