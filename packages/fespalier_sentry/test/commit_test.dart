// Since 0.19.0 the scope names a page when its navigation commits, before the page's initState and
// first build (FespalierTelemetry.commit), so an event from that frame names it. The breadcrumb of a
// page still comes with its first frame, and a navigation that commits twice names the last.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Map<String, Object?> map(Object? value) =>
    Map<String, Object?>.from(value! as Map);

/// The events (not transactions) among [sent].
List<Map<String, Object?>> events(List<Map<String, Object?>> sent) =>
    sent.where((e) => e['type'] != 'transaction').toList();

/// The one transaction among [sent].
Map<String, Object?> only(List<Map<String, Object?>> sent) {
  final transactions = sent.where((e) => e['type'] == 'transaction').toList();
  expect(transactions, hasLength(1), reason: '$transactions');
  return transactions.single;
}

/// The route tag and the transaction name the scope holds now: what a page's own code reads.
String scopeOf(Rig rig) =>
    '${rig.sentry.tags['fespalier.route']} ${rig.sentry.transactionName}';

/// The page breadcrumbs the scope holds (type `navigation`), oldest first.
List<String> pageCrumbs(Rig rig) =>
    rig.sentry.breadcrumbs.where((b) => b.startsWith('navigation ')).toList();

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
    onProbe = () {};
  });
  tearDown(() => FespalierTelemetry.install(null));

  testWidgets('the scope names the new page inside go(), before any frame', (
    tester,
  ) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    r.go('/items/7');
    expect(scopeOf(rig), '/items/:id /items/:id');
    await tester.pumpAndSettle();
    expect(scopeOf(rig), '/items/:id /items/:id');
  });

  testWidgets("a page's initState finds its own page on the scope", (
    tester,
  ) async {
    final rig = Rig();
    final seen = <String>[];
    onProbe = () => seen.add(scopeOf(rig));
    final r = await rig.boot(tester);
    r.go('/probe');
    await tester.pumpAndSettle();
    expect(seen, ['/probe /probe']);
  });

  testWidgets("the first page's initState finds its page too", (tester) async {
    final rig = Rig();
    final seen = <String>[];
    onProbe = () => seen.add(scopeOf(rig));
    await rig.boot(tester, initial: '/probe');
    expect(seen, ['/probe /probe']);
  });

  testWidgets(
    "an event captured in a page's initState on a copy of the scope names "
    'that page',
    (tester) async {
      final rig = Rig();
      onProbe = () => unawaited(
        rig.sentry.hub.captureException(
          StateError('first frame'),
          withScope: (_) {},
        ),
      );
      final r = await rig.boot(tester);
      r.go('/probe');
      await tester.pumpAndSettle();
      final sent = await rig.sent(tester);
      expect(events(sent).single['transaction'], '/probe');
      expect(await rig.lines(tester), ['event StateError route=/probe']);
    },
  );

  testWidgets(
    "fespalier's own event from a page's first frame is grouped under that "
    'page',
    (tester) async {
      final rig = Rig(capture: (_, _) => true);
      onProbe = () {
        final token = FespalierTelemetry.begin(
          const TelemetryStart(TelemetryOp.custom, name: 'fespalier.push.open'),
        );
        FespalierTelemetry.finish(
          token,
          TelemetryEnd(TelemetryOutcome.error, error: StateError('x')),
        );
      };
      final r = await rig.boot(tester);
      r.go('/probe');
      await tester.pumpAndSettle();
      final event = events(await rig.sent(tester)).single;
      expect(event['transaction'], '/probe');
      final tags = map(event['tags']);
      expect(tags['fespalier.route'], '/probe');
      expect(tags['fespalier.custom.name'], 'fespalier.push.open');
    },
  );

  testWidgets('an event on the live scope names that page, as before', (
    tester,
  ) async {
    final rig = Rig();
    onProbe = () => unawaited(rig.sentry.hub.captureException(StateError('x')));
    final r = await rig.boot(tester);
    r.go('/probe');
    await tester.pumpAndSettle();
    expect(events(await rig.sent(tester)).single['transaction'], '/probe');
  });

  testWidgets(
    'two commits before one frame: the last names the scope, and only the '
    'page shown has a breadcrumb',
    (tester) async {
      final rig = Rig();
      final r = await rig.boot(tester);
      r.go('/checkout');
      expect(scopeOf(rig), '/checkout /checkout');
      checkout = () => '/login';
      r.refresh();
      expect(scopeOf(rig), '/login /login');
      await tester.pumpAndSettle();
      expect(pageCrumbs(rig), [
        'navigation enter /home',
        'navigation enter /login',
      ]);
    },
  );

  testWidgets('no route: named at the commit, one not-found breadcrumb at the '
      'end', (tester) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    r.go('/nowhere');
    expect(rig.sentry.transactionName, 'navigate (not found)');
    expect(rig.sentry.tags.containsKey('fespalier.route'), isFalse);
    expect(rig.sentry.breadcrumbs, isNot(contains('navigation not found')));
    await tester.pumpAndSettle();
    expect(
      rig.sentry.breadcrumbs.where((b) => b == 'navigation not found'),
      hasLength(1),
    );
  });

  testWidgets('a superseded navigation never names the scope', (tester) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    final guard = Completer<String?>();
    checkout = () => guard.future;
    r.go('/checkout');
    await tester.pump();
    expect(scopeOf(rig), '/home /home');
    r.go('/items/2');
    expect(scopeOf(rig), '/items/:id /items/:id');
    guard.complete(null);
    await tester.pumpAndSettle();
    expect(scopeOf(rig), '/items/:id /items/:id');
  });

  testWidgets('a pop names the page it reveals at its commit', (tester) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    unawaited(r.push('/other'));
    await tester.pumpAndSettle();
    r.pop();
    expect(scopeOf(rig), '/home /home');
    await tester.pumpAndSettle();
    expect(rig.sentry.breadcrumbs.last, 'navigation focus /home');
    expect(
      rig.sentry.breadcrumbs.where((b) => b == 'navigation focus /home'),
      hasLength(1),
    );
  });

  testWidgets('routeTag: false names nothing at the commit either', (
    tester,
  ) async {
    final rig = Rig(routeTag: false);
    final r = await rig.boot(tester);
    r.go('/other');
    expect(rig.sentry.tags, isEmpty);
    expect(rig.sentry.transactionName, isNull);
    await tester.pumpAndSettle();
    expect(rig.sentry.tags, isEmpty);
    expect(rig.sentry.transactionName, isNull);
  });

  testWidgets(
    'with tracing: true the transaction takes the name at the commit and is '
    'sent once, with the last',
    (tester) async {
      final rig = Rig(tracing: true);
      final r = await rig.boot(tester);
      r.go('/checkout');
      expect(rig.sentry.transactionName, '/checkout');
      checkout = () => '/login';
      r.refresh();
      expect(rig.sentry.transactionName, '/login');
      await tester.pumpAndSettle();
      expect(only(await rig.sent(tester))['transaction'], '/login');
    },
  );
}
