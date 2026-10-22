// What belongs to a guard's re-run of a pushed page, and what never does (invariants 5 and 6 in
// lib/src/guards.dart). A re-run is known by go_router's own objects, its request and its entry, and
// by one flag that lives as long as the synchronous call of its `replace`. So no code that runs
// because of a re-run (a timer or a stream its guard started, a listener of its landing) is taken for
// part of it, and the person's refusal of a question while the guard waited does not decide what the
// guard's own move is asked.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/navigation_kind.dart' show pushedMatches;
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/attach_order.dart';

/// What `leave()` was asked, in order: `label` or `label dirty` (the page's `isDirty`).
final _asked = <String>[];

/// What each `leave()` answers.
var _allow = true;

/// The page `/g4` registers.
_Source? _source;

class _Source extends ChangeNotifier implements LeaveSource {
  _Source({bool dirty = false}) : _dirty = dirty;

  bool _dirty;

  set dirty(bool value) {
    _dirty = value;
    notifyListeners();
  }

  @override
  bool get isDirty => _dirty;

  @override
  bool get canKeep => false;

  @override
  FutureOr<void> keep() {}

  @override
  void discard() {}
}

class _Registrar extends StatefulWidget {
  const _Registrar(this.source, {required this.child});

  final LeaveSource source;
  final Widget child;

  @override
  State<_Registrar> createState() => _RegistrarState();
}

class _RegistrarState extends State<_Registrar> {
  VoidCallback? _unregister;

  @override
  void initState() {
    super.initState();
    _unregister = LeaveScope.maybeOf(context)?.register(widget.source);
  }

  @override
  void dispose() {
    _unregister?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A page with an app bar and a `leave.dart` that records what it is asked.
GoRoute _leaving(String path, String label, {GoRouterRedirect? redirect}) =>
    GoRoute(
      path: path,
      redirect: redirect,
      onExit: (context, state) =>
          leaveExit(context, state, '$label/leave.dart', (ref, page) {
            _asked.add(page.isDirty ? '$label dirty' : label);
            return _allow;
          }),
      pageBuilder: (context, state) {
        final held = refusedView(context, state);
        var body =
            held ??
            Scaffold(
              appBar: AppBar(),
              body: Center(child: Text(label)),
            );
        final source = label == 'g4' ? _source : null;
        if (held == null && source != null) {
          body = _Registrar(source, child: body);
        }
        return MaterialPage<void>(
          key: state.pageKey,
          child: leaveScope(state, body),
        );
      },
    );

class _Flag extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}

/// What the guard of `/g4` watches (false: it sends the page to `/z`), what the guard of `/oa`
/// watches, and a session the guards of `/` and `/login` watch.
final _g4Open = NotifierProvider<_Flag, bool>(_Flag.new);
final _baseOpen = NotifierProvider<_Flag, bool>(_Flag.new);
final _session = NotifierProvider<_Flag, bool>(_Flag.new);

/// Whether the app has to leave, set by the stream `/g4`'s guard watches.
final _expired = NotifierProvider<_Flag, bool>(_Flag.new);

/// The events of an authentication stream, which the guard of `/g4` watches (a provider that is
/// closed when nobody watches it, so it is subscribed again by every evaluation of the guard).
var _events = StreamController<int>.broadcast();
final _authEvents = StreamProvider.autoDispose<int>(
  (ref) => _events.stream.map((event) {
    ref.read(_expired.notifier).set(false);
    return event;
  }),
  retry: (_, _) => null,
);

/// When set, the guard of `/g4` answers once it completes.
Completer<void>? _gate;

/// How many times the guard of `/oa` awaits before it answers.
var _baseAwaits = 0;

/// App code that the guard of `/g4` calls once (a token service arming the expiry of a token it
/// just refreshed): it starts a timer.
var _armTimer = false;
Timer? _appTimer;

GoRouter _router() => GoRouter(
  initialLocation: '/y',
  routes: [
    GoRoute(path: '/y', builder: (_, _) => const Text('y')),
    GoRoute(path: '/p', builder: (_, _) => const Text('p')),
    _leaving('/z', 'z'),
    _leaving('/x', 'x'),
    _leaving(
      '/g4',
      'g4',
      redirect: (context, state) => runRedirect(
        () => refGuard(context, 'g4@g4', (ref) {
          ref.watch(_authEvents);
          final answer = ref.watch(_g4Open) ? null : '/z';
          if (_armTimer) {
            _armTimer = false;
            _appTimer = Timer(
              const Duration(seconds: 5),
              () => _onTimer?.call(),
            );
          }
          final wait = _gate;
          return wait == null
              ? Future<String?>.value(answer)
              : wait.future.then<String?>((_) => answer);
        }),
      ),
    ),
    // A base page with an asynchronous guard of its own.
    _leaving(
      '/oa',
      'oa',
      redirect: (context, state) => runRedirect(
        () => refGuard(context, 'ga@oa', (ref) async {
          final open = ref.watch(_baseOpen);
          for (var i = 0; i < _baseAwaits; i++) {
            await Future<void>.value();
          }
          return open ? null : '/z';
        }),
      ),
    ),
  ],
);

void Function()? _onTimer;

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _push(WidgetTester tester, GoRouter r, String location) async {
  unawaited(r.push<void>(location));
  await _settle(tester);
}

List<String> _stack(GoRouter r) {
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(r.routerDelegate.currentConfiguration.matches, pushed);
  return [
    r.routerDelegate.currentConfiguration.uri.path,
    for (final e in pushed) e.matches.uri.toString(),
  ];
}

Future<void> _systemBack(WidgetTester tester) async {
  final message = const JSONMethodCodec().encodeMethodCall(
    const MethodCall('popRoute'),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    message,
    (_) {},
  );
}

/// `/g4` (dirty) pushed over [base], `/x` over it and popped: the guard of `/g4` waits for [_gate].
/// [turnedAway] closes the guard first, so that it answers `/z`. [armTimer] makes the guard start a
/// timer of the app's.
Future<(GoRouter, ProviderContainer)> _waiting(
  WidgetTester tester, {
  String base = '/y',
  bool turnedAway = false,
  bool armTimer = false,
}) async {
  final r = _router();
  final c = await pumpRouter(tester, attached(r));
  _baseAwaits = 2;
  if (base != '/y') {
    r.go(base);
    await _settle(tester);
  }
  _source = _Source(dirty: true);
  await _push(tester, r, '/g4');
  await _push(tester, r, '/x');
  if (turnedAway) c.read(_g4Open.notifier).set(false);
  await _settle(tester);
  _gate = Completer<void>();
  _armTimer = armTimer;
  r.pop();
  await _settle(tester);
  expect(find.text('g4'), findsOneWidget, reason: 'the old page, meanwhile');
  _asked.clear();
  return (r, c);
}

void main() {
  setUp(() {
    _asked.clear();
    _allow = true;
    _source = null;
    _gate = null;
    _baseAwaits = 0;
    _armTimer = false;
    _onTimer = null;
    _events = StreamController<int>.broadcast();
  });
  tearDown(() {
    _appTimer?.cancel();
    _appTimer = null;
    unawaited(_events.close());
  });

  inEveryOrder(() {
    // The person refuses a question about the page while its guard waits. The guard then answers
    // that the page must go: that is a move of its own, asked at its landing. A clean page goes, a
    // dirty one is asked again and a refusal keeps it. (The system back used to be forgotten.)
    group('a question the person refused while the guard waited', () {
      for (final base in ['/y', '/oa']) {
        for (final how in [
          'the back button of the app bar',
          'the system back',
        ]) {
          for (final clean in [true, false]) {
            testWidgets('over $base, $how, ${clean ? 'clean' : 'dirty'}: the '
                "guard's move is asked at its landing", (tester) async {
              final (r, _) = await _waiting(
                tester,
                base: base,
                turnedAway: true,
              );
              _allow = false;
              if (how == 'the system back') {
                await _systemBack(tester);
              } else {
                await Navigator.of(tester.element(find.text('g4'))).maybePop();
              }
              await _settle(tester);
              expect(_asked, ['g4 dirty']);
              if (clean) {
                _source!.dirty = false;
                _allow = true;
              }
              _gate!.complete();
              await _settle(tester);
              if (clean) {
                expect(_asked, ['g4 dirty', 'g4']);
                expect(
                  find.text('g4'),
                  findsNothing,
                  reason: 'its guard says go',
                );
                expect(_stack(r), [base, '/z']);
              } else {
                expect(_asked, ['g4 dirty', 'g4 dirty']);
                expect(find.text('g4'), findsOneWidget);
                expect(_stack(r), [base, '/g4']);
              }
            });
          }
        }
      }
    });

    // Code that runs because the guard ran (a timer it armed, a stream its provider subscribed to
    // again) is not part of the re-run, whatever the re-run did before it: the app's own `go` from it
    // is a navigation like any other, asked as usual, and a refusal keeps the page.
    group('what the guard started is no part of the re-run', () {
      for (final how in ['a timer', 'a stream event']) {
        for (final person in ['refused a question', 'closed a dialog']) {
          testWidgets("$how, after the person $person: the app's go asks the "
              'dirty page', (tester) async {
            final (r, c) = await _waiting(tester, armTimer: how == 'a timer');
            if (how == 'a timer') {
              _onTimer = () => r.go('/p');
            } else {
              c.listen(_expired, (_, expired) {
                if (!expired) r.go('/p');
              });
            }
            if (person == 'refused a question') {
              _allow = false;
              await Navigator.of(tester.element(find.text('g4'))).maybePop();
              await _settle(tester);
              expect(_asked, ['g4 dirty']);
            } else {
              unawaited(
                showDialog<void>(
                  context: tester.element(find.text('g4')),
                  builder: (_) => const Text('dialog'),
                ),
              );
              await _settle(tester);
              await _systemBack(tester);
              await _settle(tester);
              expect(find.text('dialog'), findsNothing);
            }
            _gate!.complete();
            await _settle(tester);
            final before = _asked.length;
            expect(_stack(r), ['/y', '/g4']);
            _allow = false;
            if (how == 'a timer') {
              await tester.pump(const Duration(seconds: 6));
            } else {
              _events.add(1);
            }
            await _settle(tester);
            expect(
              _asked.length,
              before + 1,
              reason: "the app's go is asked about the dirty page",
            );
            expect(_stack(r), ['/y', '/g4'], reason: 'and a refusal keeps it');
          });
        }
      }
    });
  });

  // The base's guard stays watched through what a refused navigation leaves in the router.
  inEveryOrder(() {
    group("the base's guards stay watched", () {
      GoRouter router() => GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            redirect: (context, state) => runRedirect(
              () => refGuard(
                context,
                'b@root',
                (ref) => ref.watch(_session) ? null : '/login',
              ),
            ),
            builder: (_, _) => const Text('home'),
          ),
          GoRoute(
            path: '/login',
            redirect: (context, state) => runRedirect(
              () => refGuard(
                context,
                'l@login',
                (ref) => ref.watch(_session) ? '/' : null,
              ),
            ),
            builder: (_, _) => const Text('login'),
          ),
          _leaving('/z', 'z'),
          _leaving('/x', 'x'),
          _leaving(
            '/g4',
            'g4',
            redirect: (context, state) => runRedirect(
              () => refGuard(context, 'g4@g4', (ref) {
                final answer = ref.watch(_g4Open) && ref.watch(_session)
                    ? null
                    : '/login';
                final wait = _gate;
                return wait == null
                    ? Future<String?>.value(answer)
                    : wait.future.then<String?>((_) => answer);
              }),
            ),
          ),
        ],
      );

      Future<void> platformPush(
        WidgetTester tester,
        String location,
        Object? state,
      ) async {
        final message = const JSONMethodCodec().encodeMethodCall(
          MethodCall('pushRouteInformation', {
            'location': location,
            'state': state,
          }),
        );
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/navigation',
          message,
          (_) {},
        );
        await _settle(tester);
      }

      // The app's `replace` of a dirty pushed page is refused by its `leave()`; the browser then goes
      // back to the base page (a platform report that carries the history state, a Map). The sign-out
      // that follows moves the base page: its guard is watched.
      testWidgets('a browser back after the app\'s refused replace, then a '
          'sign-out', (tester) async {
        final r = router();
        final c = await pumpRouter(tester, attached(r));
        await _settle(tester);
        final home = r.routeInformationProvider.value;
        _source = _Source(dirty: true);
        await _push(tester, r, '/z');
        _allow = false;
        unawaited(r.replace<void>('/x'));
        await _settle(tester);
        _allow = true;
        await platformPush(tester, '/', home.state);
        expect(_stack(r), ['/']);
        c.read(_session.notifier).set(false);
        await _settle(tester);
        expect(_stack(r), ['/login'], reason: "the base's guard is watched");
      });

      // A re-run whose move the person refused, then a sign-out and a sign-in: the sign-in page's
      // own guard sends the app home.
      testWidgets('a sign-out and a sign-in after a refused move', (
        tester,
      ) async {
        final r = router();
        final c = await pumpRouter(tester, attached(r));
        await _settle(tester);
        _source = _Source(dirty: true);
        await _push(tester, r, '/g4');
        await _push(tester, r, '/x');
        _gate = Completer<void>();
        r.pop();
        await _settle(tester);
        expect(find.text('g4'), findsOneWidget);
        _allow = false;
        await Navigator.of(tester.element(find.text('g4'))).maybePop();
        await _settle(tester);
        _gate!.complete();
        _gate = null;
        await _settle(tester);
        _allow = true;
        c.read(_session.notifier).set(false);
        await _settle(tester);
        expect(_stack(r), ['/login']);
        c.read(_session.notifier).set(true);
        await _settle(tester);
        expect(_stack(r), ['/'], reason: "the sign-in page's guard is watched");
      });
    });
  });
}
