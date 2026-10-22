// ref.cancellable, PortalTransport and TransportFailures, end to end: a real Dio (the generated
// client's HTTP layer) over TransportAdapter over the decorators. A plain test(): Dio starts its
// chain with Timer.run, which testWidgets would report as pending.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// A transport whose requests wait until [release] (or until they are aborted).
final class Hanging {
  Hanging() {
    transport = FakeTransport((request, body) async {
      await _release.future;
      return fakeResponse(200, body: '{}');
    });
  }

  late final FakeTransport transport;
  final _release = Completer<void>();

  void release() => _release.complete();
}

Dio dioOver(HttpTransport transport) =>
    Dio()..httpClientAdapter = TransportAdapter(transport);

/// What the app's `CrateStackErrors` composition reads a thrown error as.
CrateStackFailure? read(Object error) =>
    TransportFailures.read(DioErrors.toTransport(error));

Future<Object?> call(Dio dio, [String path = '/x']) =>
    dio.get<Object?>(path).then<Object?>((r) => r, onError: (Object e) => e);

Future<void> settle() => Future<void>.delayed(Duration.zero);

Matcher aborted() => throwsA(
  isA<DioException>().having((e) => e.type, 'type', DioExceptionType.cancel),
);

void main() {
  group('ref.cancellable', () {
    test(
      'a request started in it is aborted when the container is disposed',
      () async {
        final hanging = Hanging();
        final dio = dioOver(hanging.transport);
        final container = ProviderContainer();
        final read = Provider<Future<Response<Object?>>>(
          (ref) => ref.cancellable(() => dio.get<Object?>('/orders')),
        );
        final request = container.read(read);
        final expectation = expectLater(request, aborted());
        while (hanging.transport.requests.isEmpty) {
          await settle();
        }
        // The zone reached the adapter: the request carries an abort trigger.
        expect(hanging.transport.requests.single.abortable, isTrue);
        expect(hanging.transport.abortCount, 0);
        container.dispose();
        await expectation;
        expect(hanging.transport.abortCount, 1);
      },
    );

    test('what Dio throws for it reads as CrateStackCancelled', () async {
      final hanging = Hanging();
      final dio = dioOver(hanging.transport);
      final container = ProviderContainer();
      final reading = Provider<Future<Object?>>(
        (ref) => ref.cancellable(() => call(dio)),
      );
      final outcome = container.read(reading);
      while (hanging.transport.requests.isEmpty) {
        await settle();
      }
      container.dispose();
      expect(read((await outcome)!), isA<CrateStackCancelled>());
    });

    test('a rebuild aborts the request of the build it replaces', () async {
      final hanging = Hanging();
      final dio = dioOver(hanging.transport);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final read = Provider<Future<Response<Object?>>>(
        (ref) => ref.cancellable(() => dio.get<Object?>('/orders')),
      );
      final first = container.read(read);
      final expectation = expectLater(first, aborted());
      while (hanging.transport.requests.isEmpty) {
        await settle();
      }
      container.invalidate(read);
      container.read(read).ignore();
      await expectation;
      hanging.release();
    });

    test(
      'every request the body makes shares the provider\'s trigger',
      () async {
        final hanging = Hanging();
        final dio = dioOver(hanging.transport);
        final container = ProviderContainer();
        final read = Provider<Future<List<Response<Object?>>>>(
          (ref) => ref.cancellable(
            () => Future.wait([dio.get<Object?>('/a'), dio.get<Object?>('/b')]),
          ),
        );
        final both = container.read(read);
        final expectation = expectLater(both, aborted());
        while (hanging.transport.requests.length < 2) {
          await settle();
        }
        container.dispose();
        await expectation;
        expect(hanging.transport.abortCount, 2);
      },
    );

    test('a request outside it carries no abort trigger', () async {
      final hanging = Hanging();
      final dio = dioOver(hanging.transport);
      final outside = dio.get<Object?>('/free');
      while (hanging.transport.requests.isEmpty) {
        await settle();
      }
      expect(hanging.transport.requests.single.abortable, isFalse);
      hanging.release();
      expect((await outside).statusCode, 200);
    });

    test('a token the request brought still aborts it inside it', () async {
      final hanging = Hanging();
      final dio = dioOver(hanging.transport);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final own = CancelToken();
      final read = Provider<Future<Response<Object?>>>(
        (ref) =>
            ref.cancellable(() => dio.get<Object?>('/x', cancelToken: own)),
      );
      final request = container.read(read);
      final expectation = expectLater(request, aborted());
      while (hanging.transport.requests.isEmpty) {
        await settle();
      }
      own.cancel('mine');
      await expectation;
      expect(hanging.transport.abortCount, 1);
    });

    test('it returns the body\'s very Future', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final future = Future<int>.value(3);
      final read = Provider<Future<int>>(
        (ref) => ref.cancellable(() => future),
      );
      expect(container.read(read), same(future));
    });

    test('on a provider that is gone, the trigger has already fired', () async {
      final hanging = Hanging();
      final dio = dioOver(hanging.transport);
      final container = ProviderContainer();
      final read = Provider<Ref>((ref) => ref);
      final ref = container.read(read);
      container.dispose();
      await expectLater(
        ref.cancellable(() => dio.get<Object?>('/gone')),
        aborted(),
      );
    });
  });

  group('PortalTransport', () {
    FakeTransport page(String type, String body) => FakeTransport(
      (_, _) => fakeResponse(200, body: body, headers: {'content-type': type}),
    );

    test(
      'a web page with a 200 becomes a portal that reads as offline',
      () async {
        final dio = dioOver(
          PortalTransport(
            page('text/html; charset=utf-8', '<html>sign in</html>'),
          ),
        );
        final out = await call(dio);
        expect(out, isA<DioException>());
        expect(DioErrors.toTransport(out!), isA<TransportPortal>());
        expect(read(out), isA<CrateStackOffline>());
      },
    );

    test('without it the page is a success that Dio hands on', () async {
      final dio = dioOver(page('text/html', '<html>sign in</html>'));
      expect(await call(dio), isA<Response<Object?>>());
    });

    test('a JSON answer passes through untouched', () async {
      final dio = dioOver(PortalTransport(page('application/json', '{"a":1}')));
      final out = await call(dio);
      expect(out, isA<Response<Object?>>());
      expect((out! as Response<Object?>).data, {'a': 1});
    });

    test(
      'the request, its attributes included, reaches the inner transport as it was',
      () async {
        final inner = FakeTransport((_, _) => fakeResponse(200));
        final memo = TransportMemo();
        final request = TransportRequest(
          method: 'POST',
          uri: Uri.parse('https://api.example.com/x'),
          attributes: {TransportMemo.key: memo, transportReplayKey: true},
        );
        await PortalTransport(inner).send(request);
        final seen = inner.requests.single.request;
        expect(identical(seen, request), isTrue);
        expect(seen.attributes[TransportMemo.key], same(memo));
      },
    );
  });

  group('TransportFailures through a real Dio', () {
    Future<CrateStackFailure?> classify(FakeTransport transport) async {
      final out = await call(dioOver(PortalTransport(transport)));
      return read(out!);
    }

    test('an envelope is read by its status and code', () async {
      final failure = await classify(
        FakeTransport(
          (_, _) => fakeResponse(
            409,
            body: '{"code":"STALE","message":"m"}',
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      expect(
        failure,
        isA<CrateStackConflict>().having((e) => e.code, 'code', 'STALE'),
      );
    });

    test('Retry-After makes a 409 in flight', () async {
      final failure = await classify(
        FakeTransport(
          (_, _) => fakeResponse(
            409,
            body: '{"code":"IDEMPOTENCY_IN_FLIGHT","message":"wait"}',
            headers: {'content-type': 'application/json', 'Retry-After': '1'},
          ),
        ),
      );
      expect(failure, isA<CrateStackInFlight>());
    });

    test('a bare 500 and a gateway page are offline', () async {
      expect(
        await classify(FakeTransport((_, _) => fakeResponse(500))),
        isA<CrateStackOffline>(),
      );
      expect(
        await classify(
          FakeTransport(
            (_, _) => fakeResponse(
              502,
              body: '<html>bad gateway</html>',
              headers: {'content-type': 'text/html'},
            ),
          ),
        ),
        isA<CrateStackOffline>(),
      );
    });

    test('no connection is offline, a timeout too', () async {
      expect(
        await classify(FakeTransport.script([const TransportUnsent('x')])),
        isA<CrateStackOffline>(),
      );
      expect(
        await classify(FakeTransport.script([const TransportTimedOut('x')])),
        isA<CrateStackOffline>(),
      );
    });

    test('a refused certificate is unknown, not offline', () async {
      expect(
        await classify(FakeTransport.script([const TransportUntrusted('x')])),
        isNull,
      );
    });

    test('a Dio badCertificate is unknown, not offline', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.badCertificate,
      );
      expect(TransportFailures.read(DioErrors.toTransport(error)), isNull);
    });

    test('a broken exchange is unknown', () async {
      expect(
        await classify(FakeTransport.script([const TransportBroken('x')])),
        isNull,
      );
    });
  });
}
