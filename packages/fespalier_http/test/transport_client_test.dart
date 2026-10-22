// TransportClient: package:http code sending through a transport chain, and a RetryClient over a
// WriteGuardTransport leaving writes alone.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';

final url = Uri.parse('https://api.example.com/items');

/// Something a session throws for its own reasons.
final class _Rejected implements Exception {}

/// What `fespalier_auth`'s `AuthUnavailable` is.
final class _Unavailable implements CredentialsUnavailable {
  @override
  Object get cause => 'offline';
}

void main() {
  group('the memo of a logical request', () {
    test('every request carries one of its own, and a copy of it is another '
        'logical request', () async {
      final transport = FakeTransport((_, _) => fakeResponse(200));
      final client = TransportClient(transport);
      final request = http.Request('GET', url);

      await client.send(request).then((r) => r.stream.drain<void>());
      final first = transport.requests.single.request.memo;
      expect(first, isNotNull);

      // package:http refuses to finalize a request twice, and a RetryClient sends a copy each
      // time: the memo follows the object, so a copy starts over (documented on TransportClient).
      final other = http.Request('GET', url);
      await client.send(other).then((r) => r.stream.drain<void>());
      final second = transport.requests.last.request.memo;
      expect(second, isNotNull);
      expect(second, isNot(same(first)), reason: 'a copy is a new request');
    });

    test('a multipart and a streamed request carry one too', () async {
      final transport = FakeTransport((_, _) => fakeResponse(200));
      final client = TransportClient(transport);
      final multipart = http.MultipartRequest('POST', url)..fields['a'] = 'b';
      await client.send(multipart).then((r) => r.stream.drain<void>());
      final streamed = http.StreamedRequest('POST', url)..sink.add([1, 2]);
      unawaited(streamed.sink.close());
      await client.send(streamed).then((r) => r.stream.drain<void>());
      for (final sent in transport.requests) {
        expect(sent.request.memo, isNotNull);
      }
    });
  });

  group('requests', () {
    test('a Request sends its bytes, headers, method and url', () async {
      final transport = FakeTransport((_, _) => fakeResponse(200));
      final client = TransportClient(transport);

      await client.post(url, headers: {'x-a': 'b'}, body: 'name=ada');

      final sent = transport.requests.single;
      expect(sent.method, 'POST');
      expect(sent.url, url);
      expect(sent.headers['x-a'], 'b');
      expect(sent.text, 'name=ada');
      expect(sent.request.body, isNotNull);
      expect(sent.request.bodyStream, isNull);
      expect(sent.request.replayable, isTrue);
    });

    test(
      'a MultipartRequest is finalized once into bytes, with its boundary',
      () async {
        final transport = FakeTransport((_, _) => fakeResponse(200));
        final request = http.MultipartRequest('POST', url)
          ..fields['name'] = 'ada'
          ..files.add(
            http.MultipartFile.fromString('note', 'hello', filename: 'n.txt'),
          );

        await TransportClient(transport).send(request);

        final sent = transport.requests.single;
        final contentType = sent.lowerHeaders['content-type']!;
        expect(contentType, startsWith('multipart/form-data; boundary='));
        final boundary = contentType.split('boundary=').last;
        expect(boundary, isNotEmpty);
        expect(sent.request.body, isNotNull);
        expect(sent.request.replayable, isTrue);
        expect(sent.text, contains('--$boundary'));
        expect(sent.text, contains('name="name"'));
        expect(sent.text, contains('hello'));
        expect(request.finalized, isTrue);
      },
    );

    test('a StreamedRequest sends a body stream with its length', () async {
      final transport = FakeTransport((_, _) => fakeResponse(200));
      final request = http.StreamedRequest('PUT', url)..contentLength = 6;

      final sending = TransportClient(transport).send(request);
      request.sink.add([1, 2, 3]);
      request.sink.add([4, 5, 6]);
      unawaited(request.sink.close());
      await sending;

      final sent = transport.requests.single;
      expect(sent.request.bodyStream, isNotNull);
      expect(sent.request.body, isNull);
      expect(sent.request.contentLength, 6);
      expect(sent.request.replayable, isFalse);
      expect(sent.body, [1, 2, 3, 4, 5, 6]);
    });

    test('the abort trigger of an Abortable request is passed on', () async {
      final transport = FakeTransport((_, _) => fakeResponse(200));
      final trigger = Completer<void>();

      await TransportClient(
        transport,
      ).send(http.AbortableRequest('GET', url, abortTrigger: trigger.future));

      expect(transport.requests.single.abortable, isTrue);
      expect(
        identical(
          transport.requests.single.request.abortTrigger,
          trigger.future,
        ),
        isTrue,
      );
    });

    test('a request without an abort trigger has none', () async {
      final transport = FakeTransport((_, _) => fakeResponse(200));

      await TransportClient(transport).get(url);

      expect(transport.requests.single.abortable, isFalse);
    });

    test('an abort ends the request with RequestAbortedException', () async {
      final transport = FakeTransport(
        (_, _) => Completer<TransportResponse>().future,
      );
      final trigger = Completer<void>();
      final pending = TransportClient(
        transport,
      ).send(http.AbortableRequest('GET', url, abortTrigger: trigger.future));
      final failed = expectLater(
        pending,
        throwsA(isA<http.RequestAbortedException>()),
      );

      trigger.complete();
      await failed;
    });
  });

  group('responses', () {
    test(
      'status, headers, reason, content length and body come back',
      () async {
        final transport = FakeTransport(
          (_, _) => TransportResponse(
            statusCode: 202,
            headers: const {'content-length': '5', 'x-a': 'b'},
            body: Stream<List<int>>.value(utf8.encode('hello')),
            reasonPhrase: 'Accepted',
          ),
        );
        final request = http.Request('GET', url);

        final response = await TransportClient(transport).send(request);

        expect(response.statusCode, 202);
        expect(response.headers['x-a'], 'b');
        expect(response.reasonPhrase, 'Accepted');
        expect(response.contentLength, 5);
        expect(identical(response.request, request), isTrue);
        expect(await response.stream.bytesToString(), 'hello');
      },
    );

    test('a content length that is not a number is unknown', () async {
      final transport = FakeTransport(
        (_, _) => fakeResponse(200, headers: {'Content-Length': 'many'}),
      );

      final response = await TransportClient(
        transport,
      ).send(http.Request('GET', url));

      expect(response.contentLength, isNull);
    });

    test('the convenience methods read the body', () async {
      final transport = FakeTransport((_, _) => fakeResponse(200, body: 'é'));

      final response = await TransportClient(transport).get(url);

      expect(response.bodyBytes, utf8.encode('é'));
    });
  });

  group('failures', () {
    Future<Object> thrownBy(Object error) async {
      try {
        await TransportClient(FakeTransport((_, _) => throw error)).get(url);
      } on Object catch (thrown) {
        return thrown;
      }
      fail('expected an error');
    }

    test('TransportAborted is RequestAbortedException', () async {
      final error = await thrownBy(TransportAborted());

      expect(error, isA<http.RequestAbortedException>());
    });

    test(
      'any other TransportFailure is a ClientException that does not name the server',
      () async {
        for (final failure in <TransportFailure>[
          TransportUnsent(),
          TransportTimedOut(),
          TransportBroken(),
        ]) {
          final error = await thrownBy(failure);

          expect(error, isA<http.ClientException>());
          final client = error as http.ClientException;
          expect(client.message, startsWith(failure.runtimeType.toString()));
          expect(client.message, isNot(contains('example.com')));
          expect(client.uri, url);
          expect(error, isNot(isA<http.RequestAbortedException>()));
        }
      },
    );

    test('CredentialsUnavailable is a ClientException', () async {
      final error = await thrownBy(_Unavailable());

      expect(error, isA<http.ClientException>());
      expect((error as http.ClientException).message, contains('_Unavailable'));
      expect(error.message, isNot(contains('example.com')));
      expect(error.uri, url);
    });

    test('any other error propagates unchanged', () async {
      final rejected = _Rejected();

      expect(identical(await thrownBy(rejected), rejected), isTrue);
      expect(await thrownBy(StateError('bug')), isA<StateError>());
    });

    test('close does nothing', () async {
      final transport = FakeTransport((_, _) => fakeResponse(200));
      final client = TransportClient(transport);

      client.close();

      expect((await client.get(url)).statusCode, 200);
    });
  });

  group('a RetryClient over TransportClient over WriteGuardTransport', () {
    RetryClient retrying(HttpTransport inner) => RetryClient(
      TransportClient(WriteGuardTransport(inner)),
      when: TransportClient.readsOnly(),
      whenError: TransportClient.readErrorsOnly((error, stackTrace) => true),
      delay: (_) => Duration.zero,
    );

    test('a POST that gets a 503 is sent once; a GET is retried', () async {
      final sent = <String>[];
      final client = retrying(
        FakeTransport((request, _) {
          sent.add(request.method);
          return fakeResponse(sent.length < 2 ? 503 : 200);
        }),
      );

      expect((await client.post(url)).statusCode, 503);
      expect(sent, ['POST']);

      sent.clear();
      expect((await client.get(url)).statusCode, 200);
      expect(sent, ['GET', 'GET']);
    });

    test('every method but the four safe ones is a write', () async {
      for (final method in ['POST', 'PUT', 'PATCH', 'DELETE']) {
        var sent = 0;
        final client = retrying(
          FakeTransport((_, _) {
            sent++;
            return fakeResponse(503);
          }),
        );

        final response = await client.send(http.Request(method, url));

        expect(response.statusCode, 503);
        expect(sent, 1, reason: method);
      }
      for (final method in ['GET', 'HEAD', 'OPTIONS']) {
        var sent = 0;
        final client = retrying(
          FakeTransport((_, _) {
            sent++;
            return fakeResponse(sent < 3 ? 503 : 200);
          }),
        );

        final response = await client.send(http.Request(method, url));

        expect(response.statusCode, 200, reason: method);
        expect(sent, 3, reason: method);
      }
    });

    test('a write with an Idempotency-Key is retried', () async {
      var sent = 0;
      final client = retrying(
        FakeTransport((_, _) {
          sent++;
          return fakeResponse(sent < 2 ? 503 : 200);
        }),
      );

      final response = await client.post(
        url,
        headers: {'Idempotency-Key': 'k-1'},
      );

      expect(response.statusCode, 200);
      expect(sent, 2);
    });

    test('a write that fails is not retried, a read that fails is', () async {
      var sent = 0;
      final client = retrying(
        FakeTransport((_, _) {
          sent++;
          if (sent < 2) throw TransportBroken();
          return fakeResponse(200);
        }),
      );

      await expectLater(client.post(url), throwsA(isA<http.ClientException>()));
      expect(sent, 1);

      sent = 0;
      expect((await client.get(url)).statusCode, 200);
      expect(sent, 2);
    });

    test('the retried copy of a body arrives as a body stream', () async {
      final transport = FakeTransport((_, _) => fakeResponse(200));

      await retrying(transport).post(url, body: 'abc');

      expect(transport.requests.single.text, 'abc');
      expect(transport.requests.single.request.bodyStream, isNotNull);
    });

    test(
      'a response from a chain without a write guard is never retried',
      () async {
        var sent = 0;
        final client = RetryClient(
          TransportClient(
            FakeTransport((_, _) {
              sent++;
              return fakeResponse(503);
            }),
          ),
          when: TransportClient.readsOnly(),
          delay: (_) => Duration.zero,
        );

        expect((await client.get(url)).statusCode, 503);
        expect(sent, 1);
      },
    );

    test(
      'readsOnly takes the rule of your own, and the errors of a read go to yours',
      () async {
        final client = TransportClient(
          WriteGuardTransport(FakeTransport((_, _) => fakeResponse(429))),
        );
        final read = await client.send(http.Request('GET', url));
        final write = await client.send(http.Request('POST', url));

        final on429 = TransportClient.readsOnly(
          (response) => response.statusCode == 429,
        );
        expect(on429(read), isTrue);
        expect(on429(write), isFalse);
        expect(TransportClient.readsOnly()(read), isFalse); // 429 is not 503
        expect(
          TransportClient.retryOn503(
            http.StreamedResponse(const Stream<List<int>>.empty(), 503),
          ),
          isTrue,
        );
        expect(
          TransportClient.retryOn503(
            http.StreamedResponse(const Stream<List<int>>.empty(), 200),
          ),
          isFalse,
        );

        var asked = 0;
        final onError = TransportClient.readErrorsOnly((error, stackTrace) {
          asked++;
          return true;
        });
        expect(onError(StateError('x'), StackTrace.empty), isTrue);
        expect(asked, 1);
      },
    );

    test('an aborted request is not retried', () async {
      var sent = 0;
      final abort = Completer<void>();
      final client = retrying(
        FakeTransport((_, _) {
          sent++;
          throw TransportAborted();
        }),
      );

      await expectLater(
        client.send(
          http.AbortableRequest('GET', url, abortTrigger: abort.future),
        ),
        throwsA(isA<http.RequestAbortedException>()),
      );
      expect(sent, 1);
    });
  });

  test('a body of bytes survives the trip untouched', () async {
    final transport = FakeTransport(
      (_, body) => TransportResponse.fromBytes(
        statusCode: 200,
        headers: const {},
        bytes: Uint8List.fromList(body.reversed.toList()),
      ),
    );

    final response = await TransportClient(
      transport,
    ).put(url, body: Uint8List.fromList([1, 2, 3]));

    expect(response.bodyBytes, [3, 2, 1]);
  });
}
