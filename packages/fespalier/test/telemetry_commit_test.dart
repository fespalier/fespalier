// `FespalierTelemetry.commit` (since 0.19.0): what a sink is told when a navigation commits, before
// the page it puts on screen is built. A `RecordingTelemetry(recordCommits: true)` keeps the
// commits as lines, and a page that writes the log it has so far from its `initState` shows what
// a page's first build could see. Most tests also check the rule `expectCommitsMatchEnds` states: a
// committed navigation's end reports the route of its last commit.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const TelemetrySite guardSite = TelemetrySite(
  'checkout/guard.dart',
  route: '/checkout',
);
const TelemetrySite redirectSite = TelemetrySite(
  'old/redirect.dart',
  route: '/old',
);

late RecordingTelemetry rec;

/// The recorder's lines a page saw when its `initState` ran.
final List<String> seen = [];

/// What the next call of the guard of `/checkout` answers.
FutureOr<String?> Function() checkout = () => null;

/// The navigation shell of the `/t1` and `/t2` tabs, once a router built one.
StatefulNavigationShell? shell;

Widget page(String label) => Scaffold(body: Text(label));

/// A page that copies what the recorder has logged so far into [seen] in its `initState`.
class Probe extends StatefulWidget {
  const Probe({super.key});

  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  @override
  void initState() {
    super.initState();
    seen.addAll(rec.log);
  }

  @override
  Widget build(BuildContext context) => page('probe');
}

/// The test router, not attached to telemetry.
GoRouter buildRouter({String initial = '/home'}) => GoRouter(
  initialLocation: initial,
  routes: [
    GoRoute(path: '/home', builder: (_, _) => page('home')),
    GoRoute(
      path: '/items/:id',
      builder: (_, s) => page('item ${s.pathParameters['id']}'),
    ),
    GoRoute(path: '/other', builder: (_, _) => page('other')),
    GoRoute(
      path: '/checkout',
      redirect: (_, state) => runRedirect(
        () => traceGuard(state, 'g1@3', checkout(), telemetry: guardSite),
      ),
      builder: (_, _) => page('checkout'),
    ),
    GoRoute(
      path: '/old',
      redirect: (_, state) => runRedirect(
        () => traceGuard(state, 'r4', '/other', telemetry: redirectSite),
      ),
    ),
    GoRoute(path: '/login', builder: (_, _) => page('login')),
    GoRoute(path: '/probe', builder: (_, _) => const Probe()),
    StatefulShellRoute.indexedStack(
      builder: (context, state, nav) {
        shell = nav;
        return nav;
      },
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/t1',
              builder: (_, _) => page('t1'),
              routes: [GoRoute(path: 'x', builder: (_, _) => page('t1 x'))],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/t2', builder: (_, _) => page('t2'))],
        ),
      ],
    ),
  ],
);

/// The test router, attached to telemetry as the generated `AppRoutes.attach` does.
GoRouter router({String initial = '/home'}) {
  final r = buildRouter(initial: initial);
  telemetryAttach(r, base: () => '/');
  return r;
}

Future<GoRouter> boot(WidgetTester tester, {String initial = '/home'}) async {
  final r = router(initial: initial);
  await pumpRouter(tester, r);
  return r;
}

/// How many microtasks and timers [body] schedules in its own zone (each is passed on to the parent).
({int microtasks, int timers}) countAsync(void Function() body) {
  var microtasks = 0;
  var timers = 0;
  runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      scheduleMicrotask: (self, parent, zone, f) {
        microtasks++;
        parent.scheduleMicrotask(zone, f);
      },
      createTimer: (self, parent, zone, d, f) {
        timers++;
        return parent.createTimer(zone, d, f);
      },
      createPeriodicTimer: (self, parent, zone, d, f) {
        timers++;
        return parent.createPeriodicTimer(zone, d, f);
      },
    ),
  );
  return (microtasks: microtasks, timers: timers);
}

/// For every `#n end navigate ok|not_found|error [route=P]` line of [log], the last `#n commit` line of
/// that navigation says the same outcome and route: a committed navigation ends on its last commit.
void expectCommitsMatchEnds(List<String> log) {
  final end = RegExp(
    r'^(#\d+) end navigate (ok|not_found|error)(?: route=(\S+))?',
  );
  var checked = 0;
  for (final line in log) {
    final m = end.firstMatch(line);
    if (m == null) continue;
    final id = m.group(1)!;
    final route = m.group(3);
    final commits = log.where((l) => l.startsWith('$id commit ')).toList();
    expect(commits, isNotEmpty, reason: 'no commit before "$line"');
    expect(
      commits.last,
      '$id commit ${m.group(2)}${route == null ? '' : ' route=$route'}',
      reason: 'the end "$line" must name the route of its last commit',
    );
    checked++;
  }
  expect(checked, greaterThan(0), reason: 'no committed navigation in $log');
}

void main() {
  setUp(() {
    rec = RecordingTelemetry(recordCommits: true);
    FespalierTelemetry.install(rec);
    checkout = () => null;
    seen.clear();
    shell = null;
  });
  tearDown(() => FespalierTelemetry.install(null));

  group('the commit of a navigation', () {
    testWidgets('the initial location commits before the first frame', (
      tester,
    ) async {
      await boot(tester);
      expect(rec.log, [
        '#1 start navigate /home',
        '#1 commit ok route=/home',
        '#1 page enter /home',
        '#1 end navigate ok route=/home kind=initial at=/home',
      ]);
    });

    testWidgets('go: the commit is told inside go(), before any pump', (
      tester,
    ) async {
      final r = await boot(tester);
      rec.log.clear();
      r.go('/items/7');
      expect(rec.log, [
        '#2 start navigate /items/7',
        '#2 commit ok route=/items/:id',
      ]);
      await tester.pumpAndSettle();
      expect(rec.log.where((l) => l.startsWith('#2 commit ')), hasLength(1));
      expect(
        rec.log.last,
        '#2 end navigate ok route=/items/:id kind=go from=/home at=/items/7',
      );
      expectCommitsMatchEnds(rec.log);
    });

    testWidgets(
      'the new page\'s initState sees its commit, not its page event or its end',
      (tester) async {
        final r = await boot(tester);
        r.go('/probe');
        await tester.pumpAndSettle();
        expect(seen, contains('#2 commit ok route=/probe'));
        expect(seen.where((l) => l.startsWith('#2 page')), isEmpty);
        expect(seen.where((l) => l.startsWith('#2 end')), isEmpty);
        expectCommitsMatchEnds(rec.log);
      },
    );

    testWidgets('the first page\'s initState sees its commit too', (
      tester,
    ) async {
      await boot(tester, initial: '/probe');
      expect(seen, contains('#1 commit ok route=/probe'));
      expect(seen.where((l) => l.startsWith('#1 end')), isEmpty);
    });

    testWidgets('push, then pop: each commit names the page on top', (
      tester,
    ) async {
      final r = await boot(tester);
      rec.log.clear();
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      expect(rec.log, contains('#2 commit ok route=/other'));
      rec.log.clear();
      r.pop();
      await tester.pumpAndSettle();
      final leave = rec.log.indexOf('#3 page leave /other');
      expect(leave, greaterThan(0));
      expect(
        rec.log.sublist(0, leave),
        containsAllInOrder([
          '#3 start navigate (commit)',
          '#3 commit ok route=/home',
        ]),
      );
      expectCommitsMatchEnds(rec.log);
    });

    testWidgets('a push whose sync guard passes commits ok with its route '
        '(fespalier/fespalier#258)', (tester) async {
      checkout = () => null;
      final r = await boot(tester);
      rec.log.clear();
      unawaited(r.push<void>('/checkout'));
      await tester.pumpAndSettle();
      expect(rec.log.where((l) => l.contains(' commit ')), [
        '#2 commit ok route=/checkout',
      ]);
      expectCommitsMatchEnds(rec.log);
      // A second push of the guarded route (another location, so another navigation) is the
      // same: it is a page of its own, and the first one is covered.
      rec.log.clear();
      unawaited(r.push<void>('/checkout?again=1'));
      await tester.pumpAndSettle();
      expect(rec.log.where((l) => l.contains(' commit ')), [
        '#4 commit ok route=/checkout',
      ]);
      expectCommitsMatchEnds(rec.log);
    });

    testWidgets('a push whose async guard passes commits ok with its route '
        '(fespalier/fespalier#258)', (tester) async {
      final answer = Completer<String?>();
      checkout = () => answer.future;
      final r = await boot(tester);
      rec.log.clear();
      unawaited(r.push<void>('/checkout'));
      await tester.pump();
      expect(rec.log.where((l) => l.startsWith('#2 commit ')), isEmpty);
      answer.complete(null);
      await tester.pumpAndSettle();
      expect(rec.log.where((l) => l.startsWith('#2 commit ')), [
        '#2 commit ok route=/checkout',
      ]);
      expectCommitsMatchEnds(rec.log);
    });

    testWidgets('a sync redirect commits where it went, and only once', (
      tester,
    ) async {
      final r = await boot(tester);
      rec.log.clear();
      r.go('/old');
      await tester.pumpAndSettle();
      expect(rec.log.where((l) => l.startsWith('#2 commit ')), [
        '#2 commit ok route=/other',
      ]);
      expectCommitsMatchEnds(rec.log);
    });

    testWidgets('an async guard commits only when it answers', (tester) async {
      final answer = Completer<String?>();
      checkout = () => answer.future;
      final r = await boot(tester);
      rec.log.clear();
      r.go('/checkout');
      await tester.pump();
      expect(rec.log.where((l) => l.startsWith('#2 commit ')), isEmpty);
      answer.complete('/login');
      await tester.pumpAndSettle();
      expect(rec.log, contains('#2 commit ok route=/login'));
      expectCommitsMatchEnds(rec.log);
    });

    testWidgets('no route: the commit is not_found, with no route', (
      tester,
    ) async {
      final r = await boot(tester);
      rec.log.clear();
      r.go('/nowhere');
      await tester.pumpAndSettle();
      expect(rec.log, contains('#2 commit not_found'));
      expect(rec.log.where((l) => l.contains('route=')), isEmpty);
    });

    testWidgets('a guard that fails: the commit is error, with no route', (
      tester,
    ) async {
      checkout = () => Future<String?>.error(StateError('boom'));
      final r = await boot(tester);
      rec.log.clear();
      r.go('/checkout');
      await tester.pumpAndSettle();
      expect(rec.log, contains('#2 commit error'));
      expect(rec.log.where((l) => l.contains('route=')), isEmpty);
      expectCommitsMatchEnds(rec.log);
    });

    testWidgets('a push whose guard fails: the commit is error, with no route, '
        'though go_router holds the error in the pushed entry', (tester) async {
      checkout = () => throw StateError('boom');
      final r = await boot(tester);
      rec.log.clear();
      unawaited(r.push<void>('/checkout'));
      await tester.pumpAndSettle();
      expect(r.routerDelegate.currentConfiguration.error, isNull);
      expect(rec.log.where((l) => l.startsWith('#2 commit ')), [
        '#2 commit error',
      ]);
      expect(rec.log.where((l) => l.contains('route=')), isEmpty);
      expectCommitsMatchEnds(rec.log);
    });

    testWidgets('a refresh after a pushed failure holds the page: each commit '
        'names no route, and the ends match them (fespalier/fespalier#258)', (
      tester,
    ) async {
      checkout = () => throw StateError('boom');
      final r = await boot(tester);
      unawaited(r.push<void>('/checkout'));
      await tester.pumpAndSettle();
      final failedPush = rec.log.singleWhere(
        (l) => l.startsWith('#2 end navigate error'),
      );
      expect(failedPush, endsWith('at=/checkout'));
      rec.log.clear();
      r.refresh();
      await tester.pumpAndSettle();
      expect(rec.log.where((l) => l.contains('route=')), isEmpty);
      expect(rec.log.where((l) => l.contains(' commit ')), isNotEmpty);
      expectCommitsMatchEnds(rec.log);
      // The held page is at the location that failed, as the failed push was; the page below it is
      // not where the navigation ended.
      final ends = rec.log.where((l) => l.contains(' end navigate ')).toList();
      expect(ends, isNotEmpty);
      expect(ends, everyElement(endsWith('at=/checkout')));
    });

    testWidgets('a refresh of a pushed page whose guard passes is two '
        'navigations: the refresh, then the re-run of the page, which both name '
        'it (fespalier/fespalier#258)', (tester) async {
      checkout = () => null;
      final r = await boot(tester);
      unawaited(r.push<void>('/checkout'));
      await tester.pumpAndSettle();
      rec.log.clear();
      r.refresh();
      await tester.pumpAndSettle();
      // The page that passed stays on screen while its guard runs again: the refresh commits it, and
      // the re-run replaces it with the same location.
      final commits = rec.log.where((l) => l.contains(' commit ')).toList();
      expect(commits, hasLength(2));
      expect(commits, everyElement(endsWith('commit ok route=/checkout')));
      expectCommitsMatchEnds(rec.log);
    });

    testWidgets('a pop while the re-run of a pushed page waits is one '
        'navigation, and the re-run that goes with it adds none '
        '(fespalier/fespalier#258)', (tester) async {
      var wait = false;
      final answer = Completer<String?>();
      checkout = () => wait ? answer.future : null;
      final r = await boot(tester);
      unawaited(r.push<void>('/checkout'));
      await tester.pumpAndSettle();
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      wait = true;
      r.pop();
      await tester.pumpAndSettle();
      expect(find.text('checkout'), findsOneWidget);
      rec.log.clear();
      // The back button of an app bar: the router is not asked, and the re-run is still waiting.
      await Navigator.of(tester.element(find.text('checkout'))).maybePop();
      await tester.pumpAndSettle();
      answer.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('checkout'), findsNothing);
      expect(rec.log.where((l) => l.contains(' commit ')), hasLength(1));
      expect(rec.log.where((l) => l.contains(' end navigate ')), hasLength(1));
      expect(rec.log.where((l) => l.contains('superseded')), isEmpty);
      expectCommitsMatchEnds(rec.log);
    });

    testWidgets('a superseded navigation never commits', (tester) async {
      final answer = Completer<String?>();
      checkout = () => answer.future;
      final r = await boot(tester);
      rec.log.clear();
      r.go('/checkout');
      await tester.pump();
      r.go('/items/2');
      await tester.pumpAndSettle();
      answer.complete(null);
      await tester.pumpAndSettle();
      expect(rec.log.where((l) => l.startsWith('#2 commit ')), isEmpty);
      expect(rec.log, contains('#4 commit ok route=/items/:id'));
      expectCommitsMatchEnds(rec.log);
    });

    testWidgets('a tab switch, and back to a branch that kept a page on top', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/t1');
      r.go('/t1/x');
      await tester.pumpAndSettle();
      rec.log.clear();
      shell!.goBranch(1);
      await tester.pumpAndSettle();
      final toTabTwo = rec.log.where((l) => l.contains(' commit '));
      expect(toTabTwo, hasLength(1));
      expect(toTabTwo.single, endsWith(' commit ok route=/t2'));
      rec.log.clear();
      shell!.goBranch(0);
      await tester.pumpAndSettle();
      final back = rec.log.where((l) => l.contains(' commit ')).toList();
      expect(back, isNotEmpty);
      expect(back.last, endsWith(' commit ok route=/t1/x'));
      expectCommitsMatchEnds(rec.log);
    });

    testWidgets(
      'two commits before one frame: both told, the end has the last',
      (tester) async {
        final r = await boot(tester);
        rec.log.clear();
        checkout = () => null;
        r.go('/checkout');
        checkout = () => '/login';
        r.refresh();
        await tester.pumpAndSettle();
        expect(rec.log.where((l) => l.startsWith('#2 commit ')), [
          '#2 commit ok route=/checkout',
          '#2 commit ok route=/login',
        ]);
        expect(rec.log.last, startsWith('#2 end navigate ok route=/login'));
      },
    );

    testWidgets('attached late: the page already on screen is told at attach', (
      tester,
    ) async {
      final r = buildRouter();
      await pumpRouter(tester, r);
      rec.log.clear();
      telemetryAttach(r, base: () => '/');
      expect(rec.log, [
        '#1 start navigate (commit)',
        '#1 commit ok route=/home',
      ]);
      // Attaching does not schedule a frame: the watch's post-frame callback (`_diff`, which tells
      // the page events and the end) runs only in a frame, and nothing has changed to draw. In an
      // app the next frame runs it. So the test asks for one, or the callback would wait for the
      // next test's first frame.
      tester.binding.scheduleFrame();
      await tester.pump();
      expect(rec.log.last, startsWith('#1 end navigate ok route=/home'));
      expectCommitsMatchEnds(rec.log);
    });

    testWidgets(
      'attached late, a throwing base loses the commit, not the frame callback',
      (tester) async {
        final r = buildRouter();
        await pumpRouter(tester, r);
        rec.log.clear();
        var calls = 0;
        // The binding checks, before any tearDown runs, that debugPrint is back as it was.
        final saved = debugPrint;
        debugPrint = (message, {wrapWidth}) {};
        try {
          telemetryAttach(
            r,
            base: () {
              if (calls++ == 0) throw StateError('base');
              return '/';
            },
          );
        } finally {
          debugPrint = saved;
        }
        expect(rec.log, ['#1 start navigate (commit)']);
        tester.binding.scheduleFrame();
        await tester.pump();
        expect(rec.log.last, startsWith('#1 end navigate ok route=/home'));
      },
    );

    testWidgets('a router telemetry does not follow tells no commit', (
      tester,
    ) async {
      final r = buildRouter();
      observeAttach(r, (_) => const []);
      await pumpRouter(tester, r);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(rec.log, isEmpty);
    });

    testWidgets('without recordCommits the log is what it was', (tester) async {
      final plain = RecordingTelemetry();
      FespalierTelemetry.install(plain);
      final r = await boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(plain.log.where((l) => l.contains(' commit ')), isEmpty);
      expect(
        plain.log,
        contains(
          '#2 end navigate ok route=/items/:id kind=go from=/home at=/items/7',
        ),
      );
    });

    testWidgets(
      'a router commit adds no microtask and no timer to a go, through a combine',
      (tester) async {
        // The unfollowed router is the baseline: its `go` is what a `go` costs with no telemetry
        // in the way. A commit the sink hears must not add to it, so `_tellCommit` and the
        // dispatcher around it stay synchronous (no microtask, no timer, not even an empty one).
        final plain = buildRouter();
        observeAttach(plain, (_) => const []);
        await pumpRouter(tester, plain);
        final baseline = countAsync(() => plain.go('/items/7'));
        await tester.pumpAndSettle();

        final a = RecordingTelemetry(recordCommits: true);
        final b = RecordingTelemetry(recordCommits: true);
        FespalierTelemetry.install(FespalierTelemetry.combine([a, b]));
        final r = await boot(tester);
        a.log.clear();
        b.log.clear();
        final followed = countAsync(() => r.go('/items/7'));
        expect(a.log, contains('#2 commit ok route=/items/:id'));
        expect(b.log, contains('#2 commit ok route=/items/:id'));
        expect(followed.microtasks, baseline.microtasks);
        expect(followed.timers, baseline.timers);
        await tester.pumpAndSettle();
        expectCommitsMatchEnds(a.log);
      },
    );

    test(
      'combine forwards a commit to every child with no microtask or timer',
      () {
        fakeAsync((async) {
          final a = RecordingTelemetry(recordCommits: true);
          final b = RecordingTelemetry(recordCommits: true);
          FespalierTelemetry.install(FespalierTelemetry.combine([a, b]));
          final nav = FespalierTelemetry.begin(
            const TelemetryStart(TelemetryOp.navigate),
          );
          FespalierTelemetry.current!.commit(
            nav,
            const TelemetryCommit(TelemetryOutcome.ok, route: '/a'),
          );
          expect(a.log.last, '#1 commit ok route=/a');
          expect(b.log.last, '#1 commit ok route=/a');
          expect(async.microtaskCount, 0);
          expect(async.pendingTimers, isEmpty);
        });
      },
    );
  });
}
