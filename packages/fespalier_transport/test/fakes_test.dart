// FakeTransport and FakeHttpCredentials, the fakes other packages' tests lean on.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final url = Uri.parse('https://api.example.com/items');

  group('FakeTransport', () {
    test(
      'answers from the handler and records the request and its body',
      () async {
        final transport = FakeTransport(
          (request, body) => fakeResponse(
            201,
            body: 'hi ${utf8.decode(body)}',
            headers: {'X-A': 'b'},
          ),
        );

        final response = await transport.send(
          TransportRequest(
            method: 'POST',
            uri: url,
            headers: const {'K': 'v'},
            body: Uint8List.fromList(utf8.encode('there')),
          ),
        );

        expect(response.statusCode, 201);
        expect(utf8.decode(await response.bytes()), 'hi there');
        expect(response.headers, {'x-a': 'b'});
        final sent = transport.requests.single;
        expect(sent.method, 'POST');
        expect(sent.url, url);
        expect(sent.headers['K'], 'v');
        expect(sent.lowerHeaders['k'], 'v');
        expect(sent.text, 'there');
        expect(sent.abortable, isFalse);
        expect(transport.abortCount, 0);
      },
    );

    test('reads a body stream into the record', () async {
      final transport = FakeTransport((_, body) => fakeResponse(200));

      await transport.send(
        TransportRequest(
          method: 'PUT',
          uri: url,
          bodyStream: Stream<List<int>>.fromIterable([
            [1, 2],
            [3],
          ]),
        ),
      );

      expect(transport.requests.single.body, [1, 2, 3]);
    });

    test('a request without a body records an empty one', () async {
      final transport = FakeTransport((_, _) => fakeResponse(200));

      await transport.send(TransportRequest(method: 'GET', uri: url));

      expect(transport.requests.single.body, isEmpty);
    });

    test('a request whose trigger fires fails with TransportAborted', () async {
      final never = Completer<TransportResponse>();
      final transport = FakeTransport((_, _) => never.future);
      final trigger = Completer<void>();
      final pending = transport.send(
        TransportRequest(method: 'GET', uri: url, abortTrigger: trigger.future),
      );
      final failed = expectLater(pending, throwsA(isA<TransportAborted>()));

      trigger.complete();
      await failed;

      expect(transport.abortCount, 1);
      expect(transport.requests.single.abortable, isTrue);
    });

    test(
      'a trigger that has already fired aborts even a handler that answers at once',
      () async {
        final transport = FakeTransport((_, _) => fakeResponse(200));

        await expectLater(
          transport.send(
            TransportRequest(
              method: 'GET',
              uri: url,
              abortTrigger: Future<void>.value(),
            ),
          ),
          throwsA(isA<TransportAborted>()),
        );
        expect(transport.abortCount, 1);
      },
    );

    test('an abortable request that is never aborted is answered', () async {
      final trigger = Completer<void>();
      final transport = FakeTransport((_, _) => fakeResponse(200, body: 'ok'));

      final response = await transport.send(
        TransportRequest(method: 'GET', uri: url, abortTrigger: trigger.future),
      );

      expect(utf8.decode(await response.bytes()), 'ok');
      expect(transport.abortCount, 0);
    });

    test('the handler may throw a TransportFailure', () async {
      final transport = FakeTransport((_, _) => throw TransportUnsent());

      await expectLater(
        transport.send(TransportRequest(method: 'GET', uri: url)),
        throwsA(isA<TransportUnsent>()),
      );
    });

    test(
      'a script answers in order, throws failures, and runs out loudly',
      () async {
        final transport = FakeTransport.script([
          fakeResponse(503),
          TransportTimedOut(),
          fakeResponse(200),
        ]);
        final request = TransportRequest(method: 'GET', uri: url);

        expect((await transport.send(request)).statusCode, 503);
        await expectLater(
          transport.send(request),
          throwsA(isA<TransportTimedOut>()),
        );
        expect((await transport.send(request)).statusCode, 200);
        await expectLater(transport.send(request), throwsStateError);
        expect(transport.requests, hasLength(4));
      },
    );

    test('the records cannot be edited', () async {
      final transport = FakeTransport((_, _) => fakeResponse(200));
      await transport.send(TransportRequest(method: 'GET', uri: url));

      expect(() => transport.requests.clear(), throwsUnsupportedError);
    });
  });

  group('fakeResponse', () {
    test(
      'lower-cases the header names and encodes the body as UTF-8',
      () async {
        final response = fakeResponse(
          200,
          body: 'é',
          headers: {'Content-Type': 'text/plain'},
        );

        expect(response.headers, {'content-type': 'text/plain'});
        expect(await response.bytes(), utf8.encode('é'));
      },
    );
  });

  group('FakeHttpCredentials', () {
    final origin = Uri.parse('https://api.example.com');
    final request = TransportRequest(method: 'GET', uri: url);

    test('covers its origins only, and attaches headers to those', () async {
      final credentials = FakeHttpCredentials(origins: [origin]);
      expect(credentials.covers(url), isTrue);
      expect(
        credentials.covers(Uri.parse('https://other.example.com/x')),
        isFalse,
      );
      expect(credentials.covers(Uri.parse('/relative')), isFalse);

      final covered = await credentials.authorize(request);
      expect(covered.headers, {'Authorization': 'Bearer fake'});
      expect(covered.isReplay, isFalse);
      final other = await credentials.authorize(
        TransportRequest(
          method: 'GET',
          uri: Uri.parse('https://other.example.com/x'),
        ),
      );

      expect(other.headers, isEmpty);
      expect(credentials.authorizeCalls, [
        'GET $url',
        'GET https://other.example.com/x',
      ]);
      expect(credentials.authorizeRequests.first, same(request));
    });

    test(
      'asks for one re-send on a retryOn status, counted through previous',
      () async {
        final credentials = FakeHttpCredentials(origins: [origin]);
        final first = await credentials.authorize(request);

        expect(await credentials.retry(first, fakeResponse(200)), isFalse);
        expect(await credentials.retry(first, fakeResponse(401)), isTrue);
        final second = await credentials.authorize(request, previous: first);
        expect(second.isReplay, isTrue);
        expect(await credentials.retry(second, fakeResponse(401)), isFalse);

        expect(credentials.retryCalls, [200, 401, 401]);
      },
    );

    test(
      'records the body of a buffered response, and null for a streamed one',
      () async {
        final credentials = FakeHttpCredentials(origins: [origin]);
        final attempt = await credentials.authorize(request);

        await credentials.retry(
          attempt,
          await TransportResponse.buffered(fakeResponse(401, body: 'nonce')),
        );
        await credentials.retry(attempt, fakeResponse(401, body: 'unread'));

        expect(credentials.retryBodies, ['nonce', null]);
      },
    );

    test('an uncovered request is never re-sent', () async {
      final credentials = FakeHttpCredentials(origins: [origin]);
      final attempt = await credentials.authorize(
        TransportRequest(
          method: 'GET',
          uri: Uri.parse('https://x.example.com/'),
        ),
      );

      expect(await credentials.retry(attempt, fakeResponse(401)), isFalse);
    });

    test('refuses an attempt of another implementation', () async {
      final credentials = FakeHttpCredentials(origins: [origin]);

      await expectLater(
        credentials.authorize(request, previous: _Stranger()),
        throwsArgumentError,
      );
      await expectLater(
        credentials.retry(_Stranger(), fakeResponse(401)),
        throwsArgumentError,
      );
    });
  });
}

final class _Stranger implements HttpAuthorization {
  @override
  Map<String, String> get headers => const {};

  @override
  bool get isReplay => false;
}
