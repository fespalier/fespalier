// `FespalierTelemetry.combine` and `add` (since 0.9.0): several sinks in the one slot, each with
// its own tokens and parents, each isolated from the others' errors; and the `within` hook that
// makes a data span or an action's span current while `data()` or the action runs, through every
// sink of a combine, the first outermost.
//
// What this file never does is print a telemetry error that is shared by the whole isolate (the
// one-per-isolate lines are in `telemetry_within_test.dart` and `telemetry_zone_test.dart`):
// every error here belongs to one sink of a combine, which keeps its own "printed once".
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/telemetry.dart'
    show telemetryNavigationEnd, telemetryNavigationStart;
import 'package:fespalier/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/misc.dart' show ProviderException;

const TelemetrySite site = TelemetrySite(
  'items/\$id/data.dart',
  route: '/items/:id',
);
const TelemetrySite actionSite = TelemetrySite(
  'items/\$id/action.dart',
  route: '/items/:id',
  name: 'rename',
);

/// What a sink that makes its operation's span current puts in the zone.
const Symbol _current = #testCurrentSpan;

/// A span: what a tracer makes. [parent] is the span that was current when it started.
final class Span {
  Span(this.name, this.parent);

  final String name;
  final Span? parent;

  @override
  String toString() => name;
}

/// A sink with tokens of its own (`name:n`), that writes every call to [log].
final class Spy extends FespalierTelemetry {
  Spy(this.name, this.log);

  final String name;
  final List<String> log;
  final List<TelemetryStart> starts = [];
  int _n = 0;

  @override
  Object? start(TelemetryStart start) {
    starts.add(start);
    log.add('$name start ${start.op.name} parent=${start.parent}');
    return '$name:${++_n}';
  }

  @override
  void end(Object? token, TelemetryEnd end) =>
      log.add('$name end $token ${end.outcome}');

  @override
  void page(Object? navigation, TelemetryPage page) =>
      log.add('$name page $navigation ${page.kind.name}');

  @override
  void within(Object? token, Object? Function() body) {
    log.add('$name within enter $token');
    final result = body();
    log.add('$name within exit $token ${result.runtimeType}');
  }
}

/// A sink like OpenTelemetry's: a span is made for each operation, a child of the span that is
/// current when it starts, and `within` makes it current with a zone value (and no error handler).
final class ZoneSpans extends FespalierTelemetry {
  final List<Span> spans = [];

  /// The span that is current here.
  static Span? get current => Zone.current[_current] as Span?;

  /// What an HTTP client's instrumentation does: a span under the current one.
  Span http(String name) {
    final span = Span(name, current);
    spans.add(span);
    return span;
  }

  @override
  Object? start(TelemetryStart start) {
    final parent = start.parent;
    final span = Span(
      '${start.op.name} ${start.site?.file ?? start.uri}',
      parent is Span ? parent : current,
    );
    spans.add(span);
    return span;
  }

  @override
  void within(Object? token, Object? Function() body) {
    if (token is! Span) {
      body();
      return;
    }
    runZoned(body, zoneValues: {_current: token});
  }
}

/// A sink like Sentry's `hub.startSpan(name, callback)`: an `async` function that runs its
/// callback at once, and is handed the result of what ran inside; the sink never returns it.
final class StartSpan extends FespalierTelemetry {
  StartSpan(this.log);

  final List<String> log;

  /// What `body()` returned, as the callback saw it.
  Object? seen;

  @override
  Object? start(TelemetryStart start) => start.op.name;

  @override
  void within(Object? token, Object? Function() body) {
    final settled = _startSpan<Object?>('data', () {
      log.add('startSpan');
      final result = body();
      seen = result;
      return result is Future<Object?> ? result : Future<Object?>.value(result);
    });
    unawaited(settled.then<void>((_) {}, onError: (Object _) {}));
  }

  Future<T> _startSpan<T>(String name, Future<T> Function() callback) async {
    return callback();
  }
}

/// A sink that throws from every call, and counts the calls.
final class Boom extends FespalierTelemetry {
  int calls = 0;

  @override
  Object? start(TelemetryStart start) {
    calls++;
    throw StateError('boom');
  }

  @override
  void end(Object? token, TelemetryEnd end) {
    calls++;
    throw StateError('boom');
  }

  @override
  void page(Object? navigation, TelemetryPage page) {
    calls++;
    throw StateError('boom');
  }

  @override
  void within(Object? token, Object? Function() body) {
    calls++;
    throw StateError('boom');
  }
}

/// A sink that has a token, and whose `within` throws.
final class WithinBoom extends FespalierTelemetry {
  int calls = 0;

  @override
  Object? start(TelemetryStart start) => 'boom';

  @override
  void within(Object? token, Object? Function() body) {
    calls++;
    throw StateError('boom');
  }
}

/// A sink that never calls through, or calls through twice.
final class Odd extends FespalierTelemetry {
  Odd({required this.times});

  final int times;

  @override
  Object? start(TelemetryStart start) => 'odd';

  @override
  void within(Object? token, Object? Function() body) {
    for (var i = 0; i < times; i++) {
      body();
    }
  }
}

/// A sink that has no token for anything.
final class Tokenless extends FespalierTelemetry {
  final List<String> log = [];

  @override
  void end(Object? token, TelemetryEnd end) => log.add('end $token');

  @override
  void page(Object? navigation, TelemetryPage page) =>
      log.add('page $navigation');

  @override
  void within(Object? token, Object? Function() body) {
    log.add('within $token');
    body();
  }
}

/// What `debugPrint` prints while [body] runs.
List<String> printed(void Function() body) {
  final lines = <String>[];
  final old = debugPrint;
  debugPrint = (message, {wrapWidth}) => lines.add('$message');
  try {
    body();
  } finally {
    debugPrint = old;
  }
  return lines;
}

void main() {
  tearDown(() => FespalierTelemetry.install(null));

  group('combine', () {
    test('no sink reports nothing, and one sink is itself', () {
      final none = FespalierTelemetry.combine([]);
      FespalierTelemetry.install(none);
      expect(
        FespalierTelemetry.begin(const TelemetryStart(TelemetryOp.data)),
        isNull,
      );
      final only = RecordingTelemetry();
      expect(identical(FespalierTelemetry.combine([only]), only), isTrue);
      // The no-op sink drops out of a bigger one.
      expect(identical(FespalierTelemetry.combine([none, only]), only), isTrue);
    });

    test('each sink gets its own token, and its own as the parent', () {
      final log = <String>[];
      final a = Spy('a', log);
      final b = Spy('b', log);
      FespalierTelemetry.install(FespalierTelemetry.combine([a, b]));
      final nav = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.navigate),
      );
      final data = FespalierTelemetry.begin(
        TelemetryStart(TelemetryOp.data, parent: nav),
      );
      FespalierTelemetry.finish(data, const TelemetryEnd('data'));
      FespalierTelemetry.finish(nav, const TelemetryEnd('ok'));
      expect(log, [
        'a start navigate parent=null',
        'b start navigate parent=null',
        'a start data parent=a:1',
        'b start data parent=b:1',
        'a end a:2 data',
        'b end b:2 data',
        'a end a:1 ok',
        'b end b:1 ok',
      ]);
    });

    test('page events go to each sink with its own navigation token', () {
      final log = <String>[];
      FespalierTelemetry.install(
        FespalierTelemetry.combine([Spy('a', log), Spy('b', log)]),
      );
      final nav = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.navigate),
      );
      log.clear();
      // `page` is what the router's watch calls; reach it through the installed sink.
      FespalierTelemetry.current!.page(
        nav,
        const TelemetryPage(TelemetryPageKind.enter, '/'),
      );
      expect(log, ['a page a:1 enter', 'b page b:1 enter']);
    });

    test('a sink with no token is still told the end, with null', () {
      final a = Tokenless();
      final b = Tokenless();
      FespalierTelemetry.install(FespalierTelemetry.combine([a, b]));
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.guard),
      );
      expect(token, isNull);
      FespalierTelemetry.finish(token, const TelemetryEnd('pass'));
      expect(a.log, ['end null']);
      expect(b.log, ['end null']);
    });

    test('a sink that has a token and a sink that has none are kept apart', () {
      final log = <String>[];
      final none = Tokenless();
      final spy = Spy('s', log);
      FespalierTelemetry.install(FespalierTelemetry.combine([none, spy]));
      final nav = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.navigate),
      );
      final data = FespalierTelemetry.begin(
        TelemetryStart(TelemetryOp.data, parent: nav),
      );
      FespalierTelemetry.finish(data, const TelemetryEnd('data'));
      expect(none.log, ['end null']);
      expect(log, [
        's start navigate parent=null',
        's start data parent=s:1',
        's end s:2 data',
      ]);
    });

    test('a combined sink in the list is flattened', () {
      final log = <String>[];
      final a = Spy('a', log);
      final b = Spy('b', log);
      final c = Spy('c', log);
      FespalierTelemetry.install(
        FespalierTelemetry.combine([
          FespalierTelemetry.combine([a, b]),
          c,
        ]),
      );
      final nav = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.navigate),
      );
      final data = FespalierTelemetry.begin(
        TelemetryStart(TelemetryOp.data, parent: nav),
      );
      FespalierTelemetry.finish(data, const TelemetryEnd('data'));
      expect(log, [
        'a start navigate parent=null',
        'b start navigate parent=null',
        'c start navigate parent=null',
        'a start data parent=a:1',
        'b start data parent=b:1',
        'c start data parent=c:1',
        'a end a:2 data',
        'b end b:2 data',
        'c end c:2 data',
      ]);
    });

    test('add puts a sink next to the installed one, and flattens', () {
      final log = <String>[];
      final a = Spy('a', log);
      final b = Spy('b', log);
      final c = Spy('c', log);
      FespalierTelemetry.install(null);
      FespalierTelemetry.add(a);
      expect(identical(FespalierTelemetry.current, a), isTrue);
      FespalierTelemetry.add(b);
      FespalierTelemetry.add(c);
      FespalierTelemetry.finish(
        FespalierTelemetry.begin(const TelemetryStart(TelemetryOp.data)),
        const TelemetryEnd('data'),
      );
      expect(log, [
        'a start data parent=null',
        'b start data parent=null',
        'c start data parent=null',
        'a end a:1 data',
        'b end b:1 data',
        'c end c:1 data',
      ]);
      // install replaces everything, install(null) removes everything.
      FespalierTelemetry.install(a);
      expect(identical(FespalierTelemetry.current, a), isTrue);
      FespalierTelemetry.install(null);
      expect(FespalierTelemetry.current, isNull);
    });

    test(
      'combine copies every field of a start, and only the parent changes',
      () {
        final log = <String>[];
        final a = Spy('a', log);
        final b = Spy('b', log);
        FespalierTelemetry.install(FespalierTelemetry.combine([a, b]));
        final nav = FespalierTelemetry.begin(
          const TelemetryStart(TelemetryOp.navigate),
        );
        final uri = Uri.parse('/orders/1?x=2');
        // Every field of TelemetryStart, set. A field added to the class goes in this list.
        final start = TelemetryStart(
          TelemetryOp.auth,
          site: site,
          file: 'a/page.dart',
          route: '/a',
          uri: uri,
          parent: nav,
          keyed: true,
          authStep: 'refresh',
          authBackend: 'oidc',
          authTrigger: 'expired',
          authDpop: true,
          source: NavigationSource.notification,
          imageCdn: 'emgr',
          imageWidth: 640,
          imagePreload: true,
          name: 'fespalier.push.open',
          attributes: const {'fespalier.push.n': 3},
        );
        FespalierTelemetry.begin(start);
        for (final (spy, parent) in [(a, 'a:1'), (b, 'b:1')]) {
          final copy = spy.starts.last;
          expect(identical(copy, start), isFalse);
          expect(copy.op, TelemetryOp.auth);
          expect(identical(copy.site, site), isTrue);
          expect(copy.file, 'a/page.dart');
          expect(copy.route, '/a');
          expect(copy.uri, uri);
          expect(copy.parent, parent);
          expect(copy.keyed, isTrue);
          expect(copy.authStep, 'refresh');
          expect(copy.authBackend, 'oidc');
          expect(copy.authTrigger, 'expired');
          expect(copy.authDpop, isTrue);
          expect(copy.source, NavigationSource.notification);
          expect(copy.imageCdn, 'emgr');
          expect(copy.imageWidth, 640);
          expect(copy.imagePreload, isTrue);
          expect(copy.name, 'fespalier.push.open');
          expect(copy.attributes, {'fespalier.push.n': 3});
        }
      },
    );

    test('a start with no parent is handed to each sink as it is', () {
      final log = <String>[];
      final a = Spy('a', log);
      final b = Spy('b', log);
      FespalierTelemetry.install(FespalierTelemetry.combine([a, b]));
      const start = TelemetryStart(TelemetryOp.navigate);
      FespalierTelemetry.begin(start);
      expect(identical(a.starts.single, start), isTrue);
      expect(identical(b.starts.single, start), isTrue);
    });

    test('a sink that throws is isolated, printed once, and called again', () {
      final log = <String>[];
      final boom = Boom();
      final other = Boom();
      final spy = Spy('s', log);
      FespalierTelemetry.install(
        FespalierTelemetry.combine([boom, spy, other]),
      );
      final lines = printed(() {
        for (var i = 0; i < 2; i++) {
          final nav = FespalierTelemetry.begin(
            const TelemetryStart(TelemetryOp.navigate),
          );
          FespalierTelemetry.finish(nav, const TelemetryEnd('ok'));
          FespalierTelemetry.current!.page(
            nav,
            const TelemetryPage(TelemetryPageKind.enter, '/'),
          );
        }
      });
      // The healthy sink recorded everything, and the throwing ones were called every time.
      expect(log, [
        's start navigate parent=null',
        's end s:1 ok',
        's page s:1 enter',
        's start navigate parent=null',
        's end s:2 ok',
        's page s:2 enter',
      ]);
      expect(boom.calls, 6);
      expect(other.calls, 6);
      // One line per sink, the first time only, naming the sink.
      expect(lines, [
        'fespalier telemetry: Bad state: boom in Boom (not shown again)',
        'fespalier telemetry: Bad state: boom in Boom (not shown again)',
      ]);
    });
  });

  group('within', () {
    test('nests the sinks in order, the first outermost, and each sees the '
        'very result', () {
      final log = <String>[];
      FespalierTelemetry.install(
        FespalierTelemetry.combine([Spy('a', log), Spy('b', log)]),
      );
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.data),
      );
      log.clear();
      final result = Object();
      final got = FespalierTelemetry.run(token, () {
        log.add('body');
        return result;
      });
      expect(identical(got, result), isTrue);
      expect(log, [
        'a within enter a:1',
        'b within enter b:1',
        'body',
        'b within exit b:1 Object',
        'a within exit a:1 Object',
      ]);
    });

    test('a sink that has no token for the operation is stepped over', () {
      final log = <String>[];
      final none = Tokenless();
      FespalierTelemetry.install(
        FespalierTelemetry.combine([none, Spy('s', log)]),
      );
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.data),
      );
      log.clear();
      expect(FespalierTelemetry.run(token, () => 7), 7);
      expect(none.log, isEmpty);
      expect(log, ['s within enter s:1', 's within exit s:1 int']);
    });

    test(
      'a sink that never calls through, or calls twice: the body runs once',
      () {
        final log = <String>[];
        FespalierTelemetry.install(
          FespalierTelemetry.combine([
            Odd(times: 0),
            Odd(times: 2),
            Spy('s', log),
          ]),
        );
        final token = FespalierTelemetry.begin(
          const TelemetryStart(TelemetryOp.data),
        );
        log.clear();
        var runs = 0;
        expect(FespalierTelemetry.run(token, () => ++runs), 1);
        expect(runs, 1);
        // The sink inside both still saw it.
        expect(log, ['s within enter s:1', 's within exit s:1 int']);
      },
    );

    test('a sink whose within throws is stepped over, printed once, and '
        'called again', () {
      final broken = WithinBoom();
      final log = <String>[];
      FespalierTelemetry.install(
        FespalierTelemetry.combine([broken, Spy('s', log)]),
      );
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.data),
      );
      log.clear();
      var runs = 0;
      final lines = printed(() {
        expect(FespalierTelemetry.run(token, () => ++runs), 1);
        expect(runs, 1);
        expect(broken.calls, 1);
        // The next operation: the sink is called again, and not shown again.
        expect(FespalierTelemetry.run(token, () => ++runs), 2);
        expect(runs, 2);
        expect(broken.calls, 2);
      });
      expect(lines, [
        'fespalier telemetry: Bad state: boom in WithinBoom (not shown again)',
      ]);
      expect(log, [
        's within enter s:1',
        's within exit s:1 int',
        's within enter s:1',
        's within exit s:1 int',
      ]);
    });

    test('an exception comes back after the sinks, and each sink saw null', () {
      final log = <String>[];
      FespalierTelemetry.install(
        FespalierTelemetry.combine([Spy('a', log), Spy('b', log)]),
      );
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.data),
      );
      log.clear();
      final error = StateError('data failed');
      Object? caught;
      StackTrace? where;
      try {
        FespalierTelemetry.run<Object>(token, () => _thrower(error));
      } catch (e, s) {
        caught = e;
        where = s;
      }
      expect(identical(caught, error), isTrue);
      expect(where.toString(), contains('_thrower'));
      expect(log, [
        'a within enter a:1',
        'b within enter b:1',
        'b within exit b:1 Null',
        'a within exit a:1 Null',
      ]);
    });

    test('with no sink, or no token, it is the call', () {
      FespalierTelemetry.install(null);
      expect(FespalierTelemetry.run(null, () => 3), 3);
      expect(FespalierTelemetry.run('token', () => 4), 4);
      FespalierTelemetry.install(RecordingTelemetry(recordWithin: true));
      final rec = FespalierTelemetry.current! as RecordingTelemetry;
      expect(FespalierTelemetry.run(null, () => 5), 5);
      expect(rec.log, isEmpty);
    });

    test('a zone sink next to another makes its span current for the body', () {
      final spans = ZoneSpans();
      FespalierTelemetry.install(
        FespalierTelemetry.combine([Spy('a', <String>[]), spans]),
      );
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.data, site: site),
      );
      Span? inside;
      FespalierTelemetry.run(token, () => inside = ZoneSpans.current);
      expect(inside?.name, 'data items/\$id/data.dart');
      // Gone when the call is over.
      expect(ZoneSpans.current, isNull);
    });
  });

  group('a Sentry-like sink nested in a zone sink', () {
    test('startSpan runs first, data() sees the zone value, the sink sees the '
        'very Future, and the provider gets its value', () async {
      final log = <String>[];
      final sentry = StartSpan(log);
      final spans = ZoneSpans();
      FespalierTelemetry.install(FespalierTelemetry.combine([sentry, spans]));
      final value = Completer<String>();
      Future<String>? future;
      Span? inside;
      final provider = FutureProvider.autoDispose<String>(
        (ref) => traceDataCall(ref, 'd1', null, () {
          log.add('data()');
          inside = ZoneSpans.current;
          return future = value.future;
        }, telemetry: site),
      );
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(provider, (_, _) {});
      expect(log, ['startSpan', 'data()']);
      expect(inside, isNotNull);
      expect(inside!.name, 'data items/\$id/data.dart');
      expect(identical(sentry.seen, future), isTrue);
      value.complete('hello');
      expect(await c.read(provider.future), 'hello');
    });

    test('a sync data() stays sync behind it, and the sink sees the value', () {
      final log = <String>[];
      final sentry = StartSpan(log);
      FespalierTelemetry.install(
        FespalierTelemetry.combine([sentry, ZoneSpans()]),
      );
      final value = Object();
      final provider = Provider.autoDispose<Object>(
        (ref) => traceDataCall(ref, 'd1', null, () => value, telemetry: site),
      );
      final c = ProviderContainer();
      addTearDown(c.dispose);
      // A value, the very object: not a Future, not even a completed one.
      expect(identical(c.read(provider), value), isTrue);
      expect(identical(sentry.seen, value), isTrue);
    });

    test('an error reaches Riverpod through both sinks', () async {
      FespalierTelemetry.install(
        FespalierTelemetry.combine([StartSpan([]), ZoneSpans()]),
      );
      final provider = FutureProvider.autoDispose<String>(
        (ref) => traceDataCall(
          ref,
          'd1',
          null,
          () => Future<String>.error(StateError('late')),
          telemetry: site,
        ),
      );
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(provider, (_, _) {});
      await expectLater(c.read(provider.future), throwsStateError);
      expect(c.read(provider), isA<AsyncError<String>>());
    });
  });

  group('the data span is current while data() runs', () {
    test(
      'an HTTP-like span made after an await is the data span\'s child',
      () async {
        final spans = ZoneSpans();
        FespalierTelemetry.install(spans);
        Span? http;
        final provider = FutureProvider.autoDispose<String>(
          (ref) => traceDataCall(ref, 'd1', 7, () async {
            await Future<void>.delayed(Duration.zero);
            http = spans.http('GET /items/7');
            return 'item 7';
          }, telemetry: site),
        );
        final c = ProviderContainer();
        addTearDown(c.dispose);
        expect(await c.read(provider.future), 'item 7');
        final data = spans.spans.first;
        expect(data.name, 'data items/\$id/data.dart');
        expect(http, isNotNull);
        expect(identical(http!.parent, data), isTrue);
        // And nothing leaked out of the call.
        expect(ZoneSpans.current, isNull);
      },
    );

    test('with traceData (0.8.1) the span starts after data(): nothing is '
        'current in it', () async {
      final spans = ZoneSpans();
      FespalierTelemetry.install(spans);
      Span? http;
      final provider = FutureProvider.autoDispose<String>(
        (ref) => traceData(ref, 'd1', 7, () async {
          await Future<void>.delayed(Duration.zero);
          http = spans.http('GET /items/7');
          return 'item 7';
        }(), telemetry: site),
      );
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(provider.future);
      expect(http!.parent, isNull);
    });

    test('a navigation is the data span\'s parent, in every sink', () {
      final log = <String>[];
      final spans = ZoneSpans();
      FespalierTelemetry.install(
        FespalierTelemetry.combine([Spy('a', log), spans]),
      );
      // What the router's watch does when a location is requested.
      final nav = telemetryNavigationStart(Uri.parse('/items/1'));
      final provider = Provider.autoDispose<int>(
        (ref) => traceDataCall(ref, 'd1', null, () => 1, telemetry: site),
      );
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(provider);
      telemetryNavigationEnd(nav, const TelemetryEnd('ok'));
      expect(log, contains('a start data parent=a:1'));
      final data = spans.spans.firstWhere((s) => s.name.startsWith('data'));
      expect(identical(data.parent, spans.spans.first), isTrue);
    });

    test('a sync data() is a value, its span starts before it runs and ends '
        'with it', () {
      final rec = RecordingTelemetry(recordWithin: true);
      FespalierTelemetry.install(rec);
      final provider = Provider.autoDispose<String>(
        (ref) => traceDataCall(ref, 'd1', null, () {
          rec.log.add('data() runs');
          return 'value';
        }, telemetry: site),
      );
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(provider), 'value');
      expect(rec.log, [
        '#1 start data items/\$id/data.dart',
        '#1 within enter',
        'data() runs',
        '#1 within exit',
        '#1 end data data',
      ]);
    });

    test('a sync throw is an error span, and Riverpod gets the error', () {
      final rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
      final error = StateError('sync');
      final provider = Provider.autoDispose<String>(
        (ref) => traceDataCall<String>(
          ref,
          'd1',
          null,
          () => throw error,
          telemetry: site,
        ),
      );
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(
        () => c.read(provider),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.exception,
            'exception',
            same(error),
          ),
        ),
      );
      expect(rec.log, [
        '#1 start data items/\$id/data.dart',
        '#1 end data error error=Bad state: sync',
      ]);
    });

    test(
      'an async failure ends the span as an error, and Riverpod gets it',
      () async {
        final rec = RecordingTelemetry();
        FespalierTelemetry.install(rec);
        final provider = FutureProvider.autoDispose<String>(
          (ref) => traceDataCall(ref, 'd1', null, () async {
            await Future<void>.delayed(Duration.zero);
            throw StateError('later');
          }, telemetry: site),
        );
        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.listen(provider, (_, _) {});
        await expectLater(c.read(provider.future), throwsStateError);
        expect(rec.log, [
          '#1 start data items/\$id/data.dart',
          '#1 end data error async error=Bad state: later',
        ]);
      },
    );
  });

  group('actions run within their span', () {
    ProviderContainer container() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('the function runs between within enter and exit', () {
      final rec = RecordingTelemetry(recordWithin: true);
      FespalierTelemetry.install(rec);
      final provider = actionProvider<String, String>(
        (ref, input) {
          rec.log.add('action runs');
          return 'done $input';
        },
        invalidates: () => const [],
        telemetry: actionSite,
      );
      final c = container();
      final result = c.read(provider.notifier)('x');
      expect(result, 'done x');
      expect(rec.log, [
        '#1 start action items/\$id/action.dart#rename',
        '#1 within enter',
        'action runs',
        '#1 within exit',
        '#1 end action ok',
      ]);
    });

    test('a sync action stays sync, and the zone value is in it', () {
      final spans = ZoneSpans();
      FespalierTelemetry.install(spans);
      Span? inside;
      final value = Object();
      final provider = actionProvider<String, Object>(
        (ref, input) {
          inside = ZoneSpans.current;
          return value;
        },
        invalidates: () => const [],
        telemetry: actionSite,
      );
      final c = container();
      final result = c.read(provider.notifier)('x');
      // The very object, not a Future.
      expect(identical(result, value), isTrue);
      expect(inside?.name, 'action items/\$id/action.dart');
    });

    test('an async action keeps the zone value after an await', () async {
      final spans = ZoneSpans();
      FespalierTelemetry.install(spans);
      Span? http;
      final provider = actionProvider<String, String>(
        (ref, input) async {
          await Future<void>.delayed(Duration.zero);
          http = spans.http('POST /items');
          return 'ok';
        },
        invalidates: () => const [],
        telemetry: actionSite,
      );
      final c = container();
      expect(await (c.read(provider.notifier)('x') as Future<String>), 'ok');
      expect(identical(http!.parent, spans.spans.first), isTrue);
    });

    test('a sync throw is the same error, and an error span', () {
      final rec = RecordingTelemetry(recordWithin: true);
      FespalierTelemetry.install(rec);
      final error = StateError('nope');
      final provider = actionProvider<String, String>(
        (ref, input) => throw error,
        invalidates: () => const [],
        telemetry: actionSite,
      );
      final c = container();
      expect(() => c.read(provider.notifier)('x'), throwsA(same(error)));
      expect(rec.log, [
        '#1 start action items/\$id/action.dart#rename',
        '#1 within enter',
        '#1 within exit',
        '#1 end action error error=Bad state: nope',
      ]);
    });

    test('an action with no site is not within anything', () {
      final rec = RecordingTelemetry(recordWithin: true);
      FespalierTelemetry.install(rec);
      final provider = actionProvider<String, String>(
        (ref, input) => input,
        invalidates: () => const [],
      );
      final c = container();
      expect(c.read(provider.notifier)('x'), 'x');
      expect(rec.log, isEmpty);
    });
  });
}

Object _thrower(Object error) => throw error;
