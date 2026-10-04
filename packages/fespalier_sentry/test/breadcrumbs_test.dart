// The breadcrumbs: one per page change, so a crash report reads as the path the user took, and a few
// for what decided it (a redirect, an action's result).
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  testWidgets(
    'a navigation is one breadcrumb, from the page it left to the page it '
    'shows',
    (tester) async {
      final rig = Rig();
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(rig.sentry.breadcrumbs, [
        'navigation enter /home',
        'navigation enter /items/:id',
      ]);
      final crumb = rig.sentry.rawBreadcrumbs.last;
      expect(crumb.type, 'navigation');
      // Sentry draws `from` and `to` as a transition: patterns, never a segment value.
      expect(crumb.data, {'from': '/home', 'to': '/items/:id'});
      expect(rig.sentry.rawBreadcrumbs.first.data, {'to': '/home'});
    },
  );

  testWidgets(
    'leaving a page is not another one: a go makes one, a pop makes one',
    (tester) async {
      final rig = Rig();
      final r = await rig.boot(tester);
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      r.pop();
      await tester.pumpAndSettle();
      expect(rig.sentry.breadcrumbs, [
        'navigation enter /home',
        'navigation enter /other',
        'navigation focus /home',
      ]);
      expect(rig.sentry.rawBreadcrumbs.last.data, {
        'from': '/other',
        'to': '/home',
      });
    },
  );

  testWidgets('a tab switch is one', (tester) async {
    final rig = Rig();
    final r = await rig.boot(tester, initial: '/t1');
    r.go('/t2');
    await tester.pumpAndSettle();
    expect(rig.sentry.breadcrumbs, [
      'navigation enter /t1',
      'navigation enter /t2',
    ]);
  });

  testWidgets('a location that is no page is a warning', (tester) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    r.go('/nowhere');
    await tester.pumpAndSettle();
    final crumb = rig.sentry.rawBreadcrumbs.last;
    expect(crumb.message, 'not found');
    expect(crumb.level?.name, 'warning');
    expect(crumb.data, {'from': '/home'});
  });

  testWidgets('a guard that redirects says which file did, and not where to', (
    tester,
  ) async {
    checkout = () => '/login';
    final rig = Rig();
    final r = await rig.boot(tester);
    r.go('/checkout');
    await tester.pumpAndSettle();
    expect(rig.sentry.breadcrumbs, [
      'navigation enter /home',
      'fespalier.guard redirect by checkout/guard.dart',
      'navigation enter /login',
    ]);
    expect(rig.sentry.rawBreadcrumbs[1].data, isEmpty);
  });

  testWidgets('recordLocations says where to', (tester) async {
    checkout = () => '/login?next=/cart';
    final rig = Rig(recordLocations: true);
    final r = await rig.boot(tester);
    r.go('/checkout');
    await tester.pumpAndSettle();
    expect(rig.sentry.rawBreadcrumbs[1].data, {
      'fespalier.guard.location': '/login',
    });
  });

  testWidgets('a guard that lets it through leaves none', (tester) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    r.go('/checkout');
    await tester.pumpAndSettle();
    expect(rig.sentry.breadcrumbs, [
      'navigation enter /home',
      'navigation enter /checkout',
    ]);
  });

  testWidgets('breadcrumbs: false leaves none, and the route tag stays', (
    tester,
  ) async {
    final rig = Rig(breadcrumbs: false);
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    expect(rig.sentry.breadcrumbs, isEmpty);
    expect(rig.sentry.tags['fespalier.route'], '/items/:id');
  });

  testWidgets('the route tag follows the page, and is gone on a page that has '
      'no pattern', (tester) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    expect(rig.sentry.tags['fespalier.route'], '/home');
    r.go('/other');
    await tester.pumpAndSettle();
    expect(rig.sentry.tags['fespalier.route'], '/other');
    r.go('/nowhere');
    await tester.pumpAndSettle();
    expect(rig.sentry.tags.containsKey('fespalier.route'), isFalse);
  });
}
