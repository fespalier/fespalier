// `FespalierSentry.configure`: fespalier's defaults on Sentry's options, row by row, and what
// its callbacks do to what Sentry puts on breadcrumbs, events and transactions.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_sentry/fespalier_sentry.dart';
import 'package:fespalier_sentry/testing.dart';
import 'package:flutter/widgets.dart' show RouteSettings;
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

const String dsn = 'https://key@sentry.invalid/1';

SentryFlutterOptions configured({
  void Function(SentryFlutterOptions options)? before,
  bool tracing = false,
  double? tracesSampleRate,
  List<String> propagateTraceTo = const [],
  bool recordQueries = false,
  bool observerBreadcrumbs = false,
}) {
  final options = SentryFlutterOptions();
  before?.call(options);
  FespalierSentry.configure(
    options,
    dsn: dsn,
    tracing: tracing,
    tracesSampleRate: tracesSampleRate,
    propagateTraceTo: propagateTraceTo,
    recordQueries: recordQueries,
    observerBreadcrumbs: observerBreadcrumbs,
  );
  return options;
}

Map<String, Object?> map(Object? value) =>
    Map<String, Object?>.from(value! as Map);

void main() {
  tearDown(() => FespalierTelemetry.install(null));

  group('the defaults', () {
    test('are errors first: the DSN, PII off, no screenshot, sessions on', () {
      final options = configured();
      expect(options.dsn, dsn);
      expect(options.sendDefaultPii, isFalse);
      expect(options.attachScreenshot, isFalse);
      // ignore: experimental_member_use
      expect(options.attachViewHierarchy, isFalse);
      expect(options.enableAutoSessionTracking, isTrue);
      // Tracing is the opt-in: nothing is sampled, and no TTFD tracker is started.
      expect(options.tracesSampleRate, isNull);
      expect(options.isTracingEnabled(), isFalse);
      expect(options.enableTimeToFullDisplayTracing, isFalse);
    });

    test('a DSN of \'\' sends nothing: the SDK is off', () {
      final options = SentryFlutterOptions();
      FespalierSentry.configure(options, dsn: '');
      expect(options.dsn, '');
    });

    test('no trace header leaves the app unless a host is listed', () {
      expect(SentryFlutterOptions().tracePropagationTargets, ['.*']);
      expect(configured().tracePropagationTargets, isEmpty);
      expect(
        configured(
          propagateTraceTo: ['api.example.com'],
        ).tracePropagationTargets,
        ['api.example.com'],
      );
    });

    test('tracing: true samples every transaction in a debug build, and asks '
        'for the time to full display', () {
      final options = configured(tracing: true);
      expect(options.tracesSampleRate, 1.0);
      expect(options.isTracingEnabled(), isTrue);
      expect(options.enableTimeToFullDisplayTracing, isTrue);
    });

    test('tracing: true keeps the rate the app set before', () {
      final options = configured(
        tracing: true,
        before: (o) => o.tracesSampleRate = 0.25,
      );
      expect(options.tracesSampleRate, 0.25);
    });

    test('a rate of its own is Sentry\'s, with or without tracing: true', () {
      expect(configured(tracesSampleRate: 0.5).tracesSampleRate, 0.5);
      expect(
        configured(tracing: true, tracesSampleRate: 0).tracesSampleRate,
        0,
      );
      expect(
        configured(tracing: true, tracesSampleRate: 1).tracesSampleRate,
        1,
      );
      // A rate alone does not make this sink trace: that is `tracing: true` on the sink.
      expect(
        configured(tracesSampleRate: 0.5).enableTimeToFullDisplayTracing,
        isFalse,
      );
    });

    test(
      'a rate outside 0..1 is refused with its value, and touches nothing',
      () {
        for (final bad in [1.5, -0.1, double.nan, double.infinity]) {
          final options = SentryFlutterOptions();
          expect(
            () => FespalierSentry.configure(
              options,
              dsn: dsn,
              tracesSampleRate: bad,
            ),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.toString(),
                'message',
                'Invalid argument (tracesSampleRate): must be between 0 and 1: $bad',
              ),
            ),
          );
          expect(options.dsn, isNull);
        }
      },
    );
  });

  group('beforeBreadcrumb', () {
    Breadcrumb http() => Breadcrumb.http(
      url: Uri.parse('https://api.example.com/items?token=abc#frag'),
      method: 'GET',
      statusCode: 200,
      httpQuery: 'token=abc',
      httpFragment: 'frag',
    );

    test('takes the query and the fragment off an HTTP breadcrumb', () {
      final crumb = configured().beforeBreadcrumb!(http(), Hint())!;
      expect(crumb.data, {
        'url': 'https://api.example.com/items',
        'method': 'GET',
        'status_code': 200,
      });
      expect(crumb.type, 'http');
      expect(crumb.category, 'http');
    });

    test('leaves another breadcrumb as it is', () {
      final crumb = Breadcrumb(message: 'hello', data: {'k': 'v?x=1'});
      expect(
        identical(configured().beforeBreadcrumb!(crumb, Hint()), crumb),
        isTrue,
      );
    });

    test('recordQueries keeps them', () {
      final crumb = configured(recordQueries: true).beforeBreadcrumb!(
        http(),
        Hint(),
      )!;
      expect(crumb.data, containsPair('http.query', 'token=abc'));
    });

    test(
      'runs after the app\'s own callback, and a breadcrumb it dropped stays '
      'dropped',
      () {
        final seen = <String>[];
        final options = configured(
          before: (o) => o.beforeBreadcrumb = (crumb, hint) {
            seen.add('app ${crumb?.message}');
            return crumb?.message == 'drop' ? null : crumb;
          },
        );
        expect(
          options.beforeBreadcrumb!(Breadcrumb(message: 'drop'), Hint()),
          isNull,
        );
        expect(
          options.beforeBreadcrumb!(Breadcrumb(message: 'keep'), Hint()),
          isNotNull,
        );
        expect(seen, ['app drop', 'app keep']);
      },
    );

    test('drops what SentryNavigatorObserver adds, which the sink\'s page '
        'breadcrumbs say with the pattern', () {
      final fromObserver = RouteObserverBreadcrumb(
        navigationType: 'didPush',
        to: const RouteSettings(name: '/items/:id'),
      );
      expect(configured().beforeBreadcrumb!(fromObserver, Hint()), isNull);
      expect(
        configured(observerBreadcrumbs: true).beforeBreadcrumb!(
          fromObserver,
          Hint(),
        ),
        isNotNull,
      );
      // The sink's own navigation breadcrumb has no `state`: it is kept.
      expect(
        configured().beforeBreadcrumb!(
          Breadcrumb(
            type: 'navigation',
            category: 'navigation',
            data: {'to': '/home'},
          ),
          Hint(),
        ),
        isNotNull,
      );
    });
  });

  group('beforeSend', () {
    SentryEvent event() => SentryEvent(
      request: SentryRequest(
        url: 'https://api.example.com/items?token=abc',
        queryString: 'token=abc',
        fragment: 'frag',
        method: 'GET',
      ),
    );

    test(
      'takes the query and the fragment off the request of an event',
      () async {
        final sent = await configured().beforeSend!(event(), Hint());
        expect(sent!.request!.url, 'https://api.example.com/items');
        expect(sent.request!.queryString, isNull);
        expect(sent.request!.fragment, isNull);
        expect(sent.request!.method, 'GET');
      },
    );

    test('an event without a request goes through', () async {
      final bare = SentryEvent();
      expect(await configured().beforeSend!(bare, Hint()), same(bare));
    });

    test('is sync when the app\'s callback is, and async when it is', () async {
      final sync = configured().beforeSend!(event(), Hint());
      expect(sync is Future, isFalse);
      final options = configured(
        before: (o) => o.beforeSend = (e, hint) async => e,
      );
      final later = options.beforeSend!(event(), Hint());
      expect(later, isA<Future<SentryEvent?>>());
      expect((await later)!.request!.queryString, isNull);
    });

    test(
      'keeps what the app\'s callback dropped dropped, sync or async',
      () async {
        final sync = configured(
          before: (o) => o.beforeSend = (e, hint) => null,
        );
        expect(sync.beforeSend!(event(), Hint()), isNull);
        final async = configured(
          before: (o) => o.beforeSend = (e, hint) async => null,
        );
        expect(await async.beforeSend!(event(), Hint()), isNull);
      },
    );

    test('recordQueries keeps the query', () async {
      final sent = await configured(recordQueries: true).beforeSend!(
        event(),
        Hint(),
      );
      expect(sent!.request!.queryString, 'token=abc');
    });

    test('is the same function through the public helpers', () {
      final e = event();
      expect(FespalierSentry.eventWithoutQueries(e, Hint()), same(e));
      expect(e.request!.queryString, isNull);
      expect(FespalierSentry.withoutQueries(null, Hint()), isNull);
    });
  });

  group('beforeSendTransaction', () {
    /// A transaction that went through a real hub, as the SDK builds it, with the data an HTTP
    /// integration puts on its spans.
    Future<Map<String, Object?>> transaction(
      RecordingSentry sentry, {
      bool superseded = false,
    }) async {
      final tx = sentry.hub.startTransaction('/items/:id', 'ui.load');
      if (superseded) tx.setTag('fespalier.navigation.outcome', 'superseded');
      final span = tx.startChild('http.client', description: 'GET /items')
        ..setData('url', 'https://api.example.com/items?token=abc')
        ..setData('http.query', 'token=abc')
        ..setData('http.fragment', 'frag')
        ..setData('http.response.status_code', 200);
      await span.finish();
      await tx.finish();
      await Future<void>.delayed(Duration.zero);
      final sent = await sentry.sent();
      return sent.isEmpty ? const {} : sent.single;
    }

    test('takes the query off the data of the spans', () async {
      final sentry = RecordingSentry(
        configure: (o) => FespalierSentry.configure(o, dsn: dsn, tracing: true),
      );
      final sent = await transaction(sentry);
      final span = map((sent['spans']! as List).single);
      final data = map(span['data']);
      expect(data['url'], 'https://api.example.com/items');
      expect(data['http.response.status_code'], 200);
      expect(data.containsKey('http.query'), isFalse);
      expect(data.containsKey('http.fragment'), isFalse);
    });

    test('recordQueries keeps it', () async {
      final sentry = RecordingSentry(
        configure: (o) => FespalierSentry.configure(
          o,
          dsn: dsn,
          tracing: true,
          recordQueries: true,
        ),
      );
      final sent = await transaction(sentry);
      expect(
        map(map((sent['spans']! as List).single)['data']),
        containsPair('http.query', 'token=abc'),
      );
    });

    test('drops a navigation that a newer one superseded, with or without '
        'recordQueries', () async {
      for (final record in [false, true]) {
        final sentry = RecordingSentry(
          configure: (o) => FespalierSentry.configure(
            o,
            dsn: dsn,
            tracing: true,
            recordQueries: record,
          ),
        );
        expect(await transaction(sentry, superseded: true), isEmpty);
      }
    });

    test('runs after the app\'s own callback', () async {
      final seen = <String?>[];
      final sentry = RecordingSentry(
        configure: (o) {
          o.beforeSendTransaction = (t, hint) {
            seen.add(t.transaction);
            return t;
          };
          FespalierSentry.configure(o, dsn: dsn, tracing: true);
        },
      );
      await transaction(sentry);
      expect(seen, ['/items/:id']);
    });
  });

  test('configure first, and the SDK still starts with Sentry\'s defaults '
      'for the rest', () {
    final options = configured();
    expect(options.environment, isNull);
    expect(options.release, isNull);
    expect(options.enableAutoPerformanceTracing, isTrue);
    expect(options.maxBreadcrumbs, 100);
  });
}
