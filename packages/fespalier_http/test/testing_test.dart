// FakeHttpClient and FakeHttpCredentials, the fakes other packages' tests lean on.
import 'dart:async';
import 'dart:convert';

import 'package:fespalier_http/fespalier_http.dart';
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

  group('FakeHttpCredentials', () {
    final origin = Uri.parse('https://api.example.com');

    test('covers its origins only, and attaches headers to those', () async {
      final credentials = FakeHttpCredentials(origins: [origin]);
      expect(credentials.covers(url), isTrue);
      expect(
        credentials.covers(Uri.parse('https://other.example.com/x')),
        isFalse,
      );
      expect(credentials.covers(Uri.parse('/relative')), isFalse);
      final covered = await credentials.authorize('GET', url);
      expect(covered.headers, {'Authorization': 'Bearer fake'});
      expect(covered.isReplay, isFalse);
      final other = await credentials.authorize(
        'GET',
        Uri.parse('https://other.example.com/x'),
      );
      expect(other.headers, isEmpty);
      expect(credentials.authorizeCalls, hasLength(2));
    });

    test(
      'asks for one re-send on a retryOn status, counted through previous',
      () async {
        final credentials = FakeHttpCredentials(origins: [origin]);
        final first = await credentials.authorize('GET', url);
        expect(
          await credentials.retry(first, statusCode: 200, headers: {}),
          isFalse,
        );
        expect(
          await credentials.retry(first, statusCode: 401, headers: {}),
          isTrue,
        );
        final second = await credentials.authorize('GET', url, previous: first);
        expect(second.isReplay, isTrue);
        expect(
          await credentials.retry(second, statusCode: 401, headers: {}),
          isFalse,
        );
        expect(credentials.retryCalls, [200, 401, 401]);
      },
    );

    test('refuses an attempt of another implementation', () async {
      final credentials = FakeHttpCredentials(origins: [origin]);
      final foreign = await FakeHttpCredentials(
        origins: [origin],
      ).authorize('GET', url);
      // Its own kind of attempt is accepted from any instance; a stranger is not.
      expect(
        credentials.authorize('GET', url, previous: _Stranger(url)),
        throwsArgumentError,
      );
      expect(
        credentials.retry(_Stranger(url), statusCode: 401, headers: {}),
        throwsArgumentError,
      );
      expect(foreign.headers, isNotEmpty);
    });
  });
}

final class _Stranger implements HttpAuthorization {
  _Stranger(this.uri);
  @override
  final Uri uri;
  @override
  String get method => 'GET';
  @override
  Map<String, String> get headers => const {};
  @override
  bool get isReplay => false;
}
