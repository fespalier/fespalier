// WriteGuardTransport marks what a write's send answered or threw, by identity, so a retrier above
// it can leave writes alone. It forwards everything unchanged.
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

TransportRequest request(String method, {Map<String, String>? headers}) =>
    TransportRequest(
      method: method,
      uri: Uri.parse('https://api.example.com/items'),
      headers: headers ?? const <String, String>{},
    );

void main() {
  group('responses', () {
    test('a write\'s response is marked as one, a read\'s is not', () async {
      final guard = WriteGuardTransport(
        FakeTransport((_, _) => fakeResponse(503)),
      );
      final read = await guard.send(request('GET'));
      final write = await guard.send(request('POST'));

      expect(WriteGuardTransport.isWriteResponse(read), isFalse);
      expect(WriteGuardTransport.isWriteResponse(write), isTrue);
    });

    test('every method but the four safe ones is a write', () async {
      final guard = WriteGuardTransport(
        FakeTransport((_, _) => fakeResponse(200)),
      );
      for (final method in ['POST', 'PUT', 'PATCH', 'DELETE']) {
        final response = await guard.send(request(method));
        expect(
          WriteGuardTransport.isWriteResponse(response),
          isTrue,
          reason: method,
        );
      }
      for (final method in ['GET', 'HEAD', 'OPTIONS', 'TRACE']) {
        final response = await guard.send(request(method));
        expect(
          WriteGuardTransport.isWriteResponse(response),
          isFalse,
          reason: method,
        );
      }
    });

    test('a write with an Idempotency-Key is not a write', () async {
      final guard = WriteGuardTransport(
        FakeTransport((_, _) => fakeResponse(200)),
      );
      final response = await guard.send(
        request('POST', headers: {'idempotency-key': 'k-1'}),
      );

      expect(WriteGuardTransport.isWriteResponse(response), isFalse);
    });

    test('a response that did not come through a guard counts as a write', () {
      expect(WriteGuardTransport.isWriteResponse(fakeResponse(200)), isTrue);
    });

    test('the response is the very object the inner transport made', () async {
      final answer = fakeResponse(200);
      final guard = WriteGuardTransport(FakeTransport((_, _) => answer));

      expect(identical(await guard.send(request('POST')), answer), isTrue);
    });

    test('the request is forwarded unchanged', () async {
      final inner = FakeTransport((_, _) => fakeResponse(200));
      final sent = request('PUT', headers: {'x-a': 'b'});

      await WriteGuardTransport(inner).send(sent);

      expect(identical(inner.requests.single.request, sent), isTrue);
    });
  });

  group('errors', () {
    test('an error a write threw is marked, a read\'s is not', () async {
      final failure = TransportBroken(StateError('boom'));
      final guard = WriteGuardTransport(FakeTransport((_, _) => throw failure));

      Object? thrownByWrite;
      try {
        await guard.send(request('POST'));
      } on Object catch (error) {
        thrownByWrite = error;
      }
      Object? thrownByRead;
      try {
        await guard.send(request('GET'));
      } on Object catch (error) {
        thrownByRead = error;
      }

      expect(identical(thrownByWrite, failure), isTrue);
      expect(WriteGuardTransport.isWriteError(failure), isTrue);
      expect(thrownByRead, isA<TransportBroken>());
    });

    test('a read\'s error is not marked', () async {
      final failure = TransportUnsent();
      final guard = WriteGuardTransport(FakeTransport((_, _) => throw failure));

      await expectLater(guard.send(request('GET')), throwsA(same(failure)));
      expect(WriteGuardTransport.isWriteError(failure), isFalse);
    });

    test('an error that is not marked says nothing', () {
      expect(WriteGuardTransport.isWriteError(StateError('x')), isFalse);
    });

    test(
      'a write that throws something an Expando cannot hold is rethrown',
      () async {
        final guard = WriteGuardTransport(
          FakeTransport((_, _) => throw 'text'),
        );

        await expectLater(guard.send(request('POST')), throwsA('text'));
      },
    );
  });

  test('an aborted write is aborted, and the guard does not hide it', () async {
    final guard = WriteGuardTransport(FakeTransport((_, _) => Future.any([])));
    final abort = Future<void>.value();

    await expectLater(
      guard.send(
        TransportRequest(
          method: 'POST',
          uri: Uri.parse('https://api.example.com/items'),
          abortTrigger: abort,
        ),
      ),
      throwsA(isA<TransportAborted>()),
    );
  });
}
