// HttpClientTransport: a TransportRequest over an http.Client, and what a client throws as a
// TransportFailure.
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_http/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A client that throws [error] for every request.
http.Client throwing(Object error) =>
    MockClient((request) async => throw error);

final url = Uri.parse('https://api.example.com/items');

Future<Object> failureOf(http.Client client) async {
  try {
    await HttpClientTransport(
      client,
    ).send(TransportRequest(method: 'GET', uri: url));
  } on Object catch (error) {
    return error;
  }
  fail('expected a failure');
}

void main() {
  group('requests', () {
    test(
      'bytes, headers and method go out as sent; the answer comes back',
      () async {
        final client = FakeHttpClient(
          (request, body) => http.Response(
            'hi ${utf8.decode(body)}',
            201,
            headers: {'X-Reply': 'yes', 'Content-Type': 'text/plain'},
            reasonPhrase: 'Created',
          ),
        );
        final transport = HttpClientTransport(client);

        final response = await transport.send(
          TransportRequest(
            method: 'POST',
            uri: url,
            headers: const {'Content-Type': 'text/plain', 'X-One': '1'},
            body: Uint8List.fromList(utf8.encode('there')),
          ),
        );

        final sent = client.requests.single;
        expect(sent.method, 'POST');
        expect(sent.url, url);
        expect(sent.headers['X-One'], '1');
        expect(sent.headers['Content-Type'], 'text/plain');
        expect(utf8.decode(sent.body), 'there');
        expect(response.statusCode, 201);
        expect(response.reasonPhrase, 'Created');
        expect(response.headers['x-reply'], 'yes');
        expect(
          response.headers.keys.every((name) => name == name.toLowerCase()),
          isTrue,
        );
        expect(utf8.decode(await response.bytes()), 'hi there');
      },
    );

    test('a request without a body sends none', () async {
      final client = FakeHttpClient((_, _) => http.Response('', 204));

      await HttpClientTransport(
        client,
      ).send(TransportRequest(method: 'GET', uri: url));

      expect(client.requests.single.body, isEmpty);
    });

    test('a body stream is piped, with its length when known', () async {
      final seen = <http.BaseRequest>[];
      final client = FakeHttpClient((request, body) {
        seen.add(request);
        return http.Response('', 200);
      });

      await HttpClientTransport(client).send(
        TransportRequest(
          method: 'PUT',
          uri: url,
          bodyStream: Stream<List<int>>.fromIterable([
            [1, 2, 3],
            [4, 5, 6],
          ]),
          contentLength: 6,
        ),
      );

      expect(client.requests.single.body, [1, 2, 3, 4, 5, 6]);
      expect(seen.single, isA<http.AbortableStreamedRequest>());
      expect(seen.single.contentLength, 6);
    });

    test('a body stream of unknown length has no content length', () async {
      final seen = <http.BaseRequest>[];
      final client = FakeHttpClient((request, _) {
        seen.add(request);
        return http.Response('', 200);
      });

      await HttpClientTransport(client).send(
        TransportRequest(
          method: 'PUT',
          uri: url,
          bodyStream: Stream<List<int>>.value([1]),
        ),
      );

      expect(seen.single.contentLength, isNull);
    });

    test(
      'the abort trigger is passed on, and an abort is TransportAborted',
      () async {
        final never = Completer<http.Response>();
        final client = FakeHttpClient((_, _) => never.future);
        final trigger = Completer<void>();
        final pending = HttpClientTransport(client).send(
          TransportRequest(
            method: 'GET',
            uri: url,
            abortTrigger: trigger.future,
          ),
        );
        final failed = expectLater(
          pending,
          throwsA(
            isA<TransportAborted>()
                .having(
                  (f) => f.cause,
                  'cause',
                  isA<http.RequestAbortedException>(),
                )
                .having((f) => f.uri, 'uri', url),
          ),
        );

        trigger.complete();
        await failed;

        expect(client.requests.single.abortable, isTrue);
        expect(client.abortCount, 1);
      },
    );

    test('attributes are not sent anywhere', () async {
      final client = FakeHttpClient((_, _) => http.Response('', 200));

      await HttpClientTransport(client).send(
        TransportRequest(
          method: 'GET',
          uri: url,
          attributes: const {transportReplayKey: true},
        ),
      );

      expect(
        client.requests.single.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('fespalier.auth.replay')),
      );
    });

    test('the transport does not close the client', () async {
      final client = FakeHttpClient((_, _) => http.Response('', 200));

      await HttpClientTransport(
        client,
      ).send(TransportRequest(method: 'GET', uri: url));

      expect(client.isClosed, isFalse);
    });
  });

  group('failures', () {
    test('a TimeoutException is TransportTimedOut', () async {
      final error = TimeoutException('slow');

      final failure = await failureOf(throwing(error));

      expect(failure, isA<TransportTimedOut>());
      expect((failure as TransportFailure).cause, same(error));
      expect(failure.uri, url);
    });

    test(
      'a refused connection, a failed lookup and an unreachable network are TransportUnsent',
      () async {
        for (final text in [
          'SocketException: Connection refused (OS Error: Connection refused, errno = 61), address = x, port = 80',
          'SocketException: Failed host lookup: api.example.com (OS Error: nodename nor servname provided, or not known, errno = 8)',
          'SocketException: Network is unreachable (OS Error: Network is unreachable, errno = 101)',
          'SocketException: No route to host',
          'Connection refused',
          'SocketException: OS Error: x, errno = 111',
          'SocketException: OS Error: x, errno = 10061',
          'SocketException: HTTP connection timed out after 0:00:05.000000, host: x, port: 443',
        ]) {
          final error = http.ClientException(text, url);

          final failure = await failureOf(throwing(error));

          expect(failure, isA<TransportUnsent>(), reason: text);
          expect((failure as TransportFailure).cause, same(error));
        }
      },
    );

    test('any other ClientException is TransportBroken', () async {
      for (final text in [
        'Connection closed before full header was received',
        'SocketException: Connection reset by peer (OS Error: Connection reset by peer, errno = 54)',
        'SocketException: Connection timed out (OS Error: Connection timed out, errno = 60)',
        'HandshakeException: Handshake error in client',
        'XMLHttpRequest error.',
        'errno = 99999',
      ]) {
        final failure = await failureOf(
          throwing(http.ClientException(text, url)),
        );

        expect(failure, isA<TransportBroken>(), reason: text);
      }
    });

    test(
      'a dart:io style error thrown unwrapped is classified by its text',
      () async {
        expect(
          await failureOf(throwing(_SocketException('Connection refused'))),
          isA<TransportUnsent>(),
        );
        expect(
          await failureOf(throwing(_SocketException('reset by peer'))),
          isA<TransportBroken>(),
        );
        expect(
          await failureOf(throwing(_HandshakeException('bad certificate'))),
          isA<TransportBroken>(),
        );
        expect(
          await failureOf(throwing(_HttpException('Connection closed'))),
          isA<TransportBroken>(),
        );
      },
    );

    test(
      'a refused certificate is TransportUntrusted, whichever dart:io error says so',
      () async {
        for (final error in <Object>[
          const io.HandshakeException('CERTIFICATE_VERIFY_FAILED'),
          const io.TlsException('bad'),
          io.CertificateException('bad'),
        ]) {
          final failure = await failureOf(throwing(error));

          expect(failure, isA<TransportUntrusted>(), reason: '$error');
          expect((failure as TransportFailure).cause, same(error));
          expect(failure.uri, url);
        }
      },
    );

    test('a certificate error beats a connection phrase in its text', () {
      final failure = HttpClientTransport.classify(
        const io.HandshakeException('Connection refused'),
        url,
      );
      expect(failure, isA<TransportUntrusted>());
    });

    test('a programming error is not a transport failure', () async {
      expect(await failureOf(throwing(StateError('bug'))), isA<StateError>());
      expect(
        await failureOf(throwing(ArgumentError('bug'))),
        isA<ArgumentError>(),
      );
    });

    test('classify is the rule, with the uri kept', () {
      final unsent = HttpClientTransport.classify('Connection refused', url);
      final broken = HttpClientTransport.classify('Connection reset', url);

      expect(unsent, isA<TransportUnsent>());
      expect(unsent.uri, url);
      expect(broken, isA<TransportBroken>());
      expect(unsent.toString(), isNot(contains('example.com')));
    });
  });
}

// Stand-ins for dart:io's errors, found by the name of their type.
final class _SocketException implements Exception {
  _SocketException(this.message);
  final String message;
  @override
  String toString() => 'SocketException: $message';
}

final class _HandshakeException implements Exception {
  _HandshakeException(this.message);
  final String message;
  @override
  String toString() => 'HandshakeException: $message';
}

final class _HttpException implements Exception {
  _HttpException(this.message);
  final String message;
  @override
  String toString() => 'HttpException: $message';
}
