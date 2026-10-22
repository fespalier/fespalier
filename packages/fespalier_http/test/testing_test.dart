// FakeHttpClient, the fake other packages' tests lean on. (FakeHttpCredentials and FakeTransport
// are fespalier_transport's.)
import 'dart:async';
import 'dart:convert';

import 'package:fespalier_http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  final url = Uri.parse('https://api.example.com/items');

  group('FakeHttpClient', () {
    test(
      'answers from the handler and records the request and its body',
      () async {
        final client = FakeHttpClient(
          (request, body) => http.Response(
            'hi ${utf8.decode(body)}',
            201,
            headers: {'x-a': 'b'},
          ),
        );
        final response = await client.post(
          url,
          body: 'there',
          headers: {'k': 'v'},
        );
        expect(response.statusCode, 201);
        expect(response.body, 'hi there');
        expect(response.headers['x-a'], 'b');
        expect(client.requests, hasLength(1));
        expect(client.requests.single.method, 'POST');
        expect(client.requests.single.url, url);
        expect(client.requests.single.headers['k'], 'v');
        expect(utf8.decode(client.requests.single.body), 'there');
        expect(client.requests.single.abortable, isFalse);
        expect(client.abortCount, 0);
        client.close();
        expect(client.isClosed, isTrue);
      },
    );

    test(
      'a request whose trigger fires fails with RequestAbortedException',
      () async {
        final never = Completer<http.Response>();
        final client = FakeHttpClient((_, _) => never.future);
        final trigger = Completer<void>();
        final pending = client.send(
          http.AbortableRequest('GET', url, abortTrigger: trigger.future),
        );
        final failed = expectLater(
          pending,
          throwsA(isA<http.RequestAbortedException>()),
        );
        trigger.complete();
        await failed;
        expect(client.abortCount, 1);
        expect(client.requests.single.abortable, isTrue);
      },
    );

    test(
      'a trigger that has already fired aborts even a handler that answers at once',
      () async {
        final client = FakeHttpClient((_, _) => http.Response('ok', 200));
        await expectLater(
          client.send(
            http.AbortableRequest(
              'GET',
              url,
              abortTrigger: Future<void>.value(),
            ),
          ),
          throwsA(isA<http.RequestAbortedException>()),
        );
        expect(client.abortCount, 1);
      },
    );

    test('an abortable request that is never aborted is answered', () async {
      final trigger = Completer<void>();
      final client = FakeHttpClient((_, _) => http.Response('ok', 200));
      final streamed = await client.send(
        http.AbortableRequest('GET', url, abortTrigger: trigger.future),
      );
      expect(streamed.statusCode, 200);
      expect(await streamed.stream.bytesToString(), 'ok');
      expect(client.abortCount, 0);
    });
  });
}
