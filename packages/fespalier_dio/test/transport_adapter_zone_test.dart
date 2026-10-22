// TransportAdapter merges Dio's cancel future with the abort trigger of the zone the request was
// made in (TransportZone, what ref.cancellable in fespalier_cratestack sets). Plain test(): Dio
// starts its interceptor chain with Timer.run.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const base = 'https://api.example.com';

/// A transport whose answer never comes, so only an abort can end the request; [started]
/// completes when the request reaches it.
FakeTransport hanging(Completer<void> started) =>
    FakeTransport((request, body) {
      started.complete();
      return Completer<TransportResponse>().future;
    });

void main() {
  test(
    'a request made in a zone with a trigger has it as abortTrigger',
    () async {
      final transport = FakeTransport((request, body) => fakeResponse(200));
      final dio = Dio()..httpClientAdapter = TransportAdapter(transport);
      final trigger = Completer<void>();
      await TransportZone.run(
        trigger.future,
        () => dio.get<Object?>('$base/orders'),
      );
      expect(transport.requests.single.abortable, isTrue);
      expect(transport.requests.single.request.abortTrigger, isNotNull);
    },
  );

  test('a request outside any zone has none', () async {
    final transport = FakeTransport((request, body) => fakeResponse(200));
    final dio = Dio()..httpClientAdapter = TransportAdapter(transport);
    await dio.get<Object?>('$base/orders');
    expect(transport.requests.single.abortable, isFalse);
  });

  test('completing the zone trigger aborts the send mid-flight', () async {
    final started = Completer<void>();
    final transport = hanging(started);
    final dio = Dio()..httpClientAdapter = TransportAdapter(transport);
    final trigger = Completer<void>();
    final call = TransportZone.run(
      trigger.future,
      () => dio.get<Object?>('$base/orders'),
    );
    final failure = expectLater(
      call,
      throwsA(
        isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)
            .having((e) => e.error, 'error', isA<TransportAborted>()),
      ),
    );
    await started.future;
    trigger.complete();
    await failure;
    expect(transport.abortCount, 1);
  });

  test(
    'Dio\'s own cancel token still aborts when a zone trigger exists',
    () async {
      final started = Completer<void>();
      final transport = hanging(started);
      final dio = Dio()..httpClientAdapter = TransportAdapter(transport);
      final trigger = Completer<void>();
      final token = CancelToken();
      final call = TransportZone.run(
        trigger.future,
        () => dio.get<Object?>('$base/orders', cancelToken: token),
      );
      final failure = expectLater(
        call,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await started.future;
      token.cancel('page gone');
      await failure;
      expect(transport.abortCount, 1);
    },
  );

  test('a zone trigger that never completes lets the request finish', () async {
    final transport = FakeTransport((request, body) => fakeResponse(200));
    final dio = Dio()..httpClientAdapter = TransportAdapter(transport);
    final trigger = Completer<void>();
    final response = await TransportZone.run(
      trigger.future,
      () => dio.get<Object?>('$base/orders'),
    );
    expect(response.statusCode, 200);
    expect(transport.abortCount, 0);
  });
}
