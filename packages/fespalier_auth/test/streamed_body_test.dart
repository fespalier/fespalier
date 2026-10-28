// A response body that streams (server-sent events, a download) through the real SessionTransport
// and two decorators that behave as OtelTransport and SentryTransport do (they see the response
// when its headers arrive and hand it on, never reading the body), over a FakeTransport whose body
// is a StreamController the test feeds:
//
// - a 200's body is handed on as the very stream the transport gave, unread: its first chunk
//   reaches the caller while the server is still sending;
// - a 401's body is read for the authenticator up to 64 KiB only: a larger one (by its
//   content-length, or once more than 64 KiB arrived) is handed on with the rest still streaming;
// - a 401 that renews is read to its end (and dropped) before the request is sent again.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final api = Uri.parse('https://api.example.com');
final events = Uri.parse('https://api.example.com/events');

const kib = 1024;

/// What a telemetry decorator does with a response: it notes it when the headers arrive and hands
/// it on as it is (OtelTransport ends its span there, SentryTransport adds its breadcrumb there).
final class Recorder implements HttpTransport {
  Recorder(this.inner, this.log, this.name);

  final HttpTransport inner;
  final List<String> log;
  final String name;

  /// The responses it handed on, oldest first.
  final List<TransportResponse> handed = [];

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final response = await inner.send(request);
    log.add('$name ${response.statusCode}');
    handed.add(response);
    return response;
  }
}

/// A body the test writes chunk by chunk, logging when it is listened to.
final class Body {
  Body(this.log);

  final List<String> log;
  late final controller = StreamController<List<int>>(
    onListen: () => log.add('body listened'),
  );

  Stream<List<int>> get stream => controller.stream;

  void add(String text) => controller.add(utf8.encode(text));

  void addBytes(int count) => controller.add(Uint8List(count));
}

void main() {
  late FakeAuthBackend backend;
  late ProviderContainer container;
  late List<String> log;

  setUp(() {
    log = [];
    backend = FakeAuthBackend(user: ada);
    container = containerFor(
      signedInAs: ada,
      backend: backend,
      apiOrigins: [api],
    );
  });

  /// `SessionTransport(otel-like(sentry-like(inner)))`, the order an app stacks them in.
  ({SessionTransport session, Recorder otel, Recorder sentry}) chain(
    HttpTransport inner,
  ) {
    final sentry = Recorder(inner, log, 'sentry');
    final otel = Recorder(sentry, log, 'otel');
    return (
      session: SessionTransport(otel, container.read(authorizer)),
      otel: otel,
      sentry: sentry,
    );
  }

  TransportRequest get() => TransportRequest(
    method: 'GET',
    uri: events,
    headers: const {'accept': 'text/event-stream'},
  );

  test(
    'a 200 is handed on unread: the first event arrives while the server sends',
    () async {
      final body = Body(log);
      addTearDown(body.controller.close);
      final inner = FakeTransport(
        (request, _) => TransportResponse(
          statusCode: 200,
          headers: const {'content-type': 'text/event-stream'},
          body: body.stream,
        ),
      );
      final stack = chain(inner);

      final response = await stack.session.send(get());
      expect(response.statusCode, 200);
      expect(response.isBuffered, isFalse);
      // The very response every decorator saw, handed on before anything read its body.
      expect(identical(stack.sentry.handed.single, response), isTrue);
      expect(identical(stack.otel.handed.single, response), isTrue);
      expect(log, ['sentry 200', 'otel 200']);
      expect(body.controller.hasListener, isFalse);

      final received = <String>[];
      final done = Completer<void>();
      final sub = response.body
          .map(utf8.decode)
          .listen(received.add, onDone: done.complete);
      body.add(': hi\n\n');
      body.add('data: 1\n\n');
      await pumpEventQueue();
      expect(received, [': hi\n\n', 'data: 1\n\n']);
      expect(body.controller.isClosed, isFalse);
      expect(done.isCompleted, isFalse);

      body.add('data: 2\n\n');
      await body.controller.close();
      await done.future;
      expect(received.last, 'data: 2\n\n');
      await sub.cancel();
      expect(inner.requests, hasLength(1));
      expect(backend.authenticator.judged, [200]);
    },
  );

  test(
    'a 200 cancelled by the caller cancels the server stream (nothing buffers it)',
    () async {
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final inner = FakeTransport(
        (request, _) => TransportResponse(
          statusCode: 200,
          headers: const {'content-type': 'text/event-stream'},
          body: controller.stream,
        ),
      );
      final response = await chain(inner).session.send(get());
      final first = Completer<List<int>>();
      final sub = response.body.listen(first.complete);
      controller.add(utf8.encode('data: 1\n\n'));
      await first.future;
      await sub.cancel();
      expect(cancelled, isTrue);
    },
  );

  group('a 401 whose body is over 64 KiB', () {
    test(
      'by its content-length: handed on unread when the authenticator accepts',
      () async {
        backend.authenticator.verdict = (_, _, _, _, _, _) => const Accept();
        final body = Body(log);
        addTearDown(body.controller.close);
        final inner = FakeTransport(
          (request, _) => TransportResponse(
            statusCode: 401,
            headers: {'content-length': '${65 * kib}'},
            body: body.stream,
          ),
        );

        final response = await chain(inner).session.send(get());
        expect(response.statusCode, 401);
        expect(response.isBuffered, isFalse);
        // Nobody listened: the authenticator was asked with no body.
        expect(log, ['sentry 401', 'otel 401']);
        expect(body.controller.hasListener, isFalse);
        expect(backend.authenticator.judged, [401]);

        final bytes = response.bytes();
        body.addBytes(65 * kib);
        await body.controller.close();
        expect((await bytes).length, 65 * kib);
        expect(inner.requests, hasLength(1));
      },
    );

    test(
      'with no content-length: handed on once more than 64 KiB arrived, the rest streaming',
      () async {
        String? judgedBody = 'not asked';
        backend.authenticator.verdict = (_, _, _, _, body, _) {
          judgedBody = body;
          return const Accept();
        };
        final body = Body(log);
        addTearDown(body.controller.close);
        final inner = FakeTransport(
          (request, _) => TransportResponse(
            statusCode: 401,
            headers: const {},
            body: body.stream,
          ),
        );

        TransportResponse? response;
        final sent = chain(inner).session.send(get()).then((r) => response = r);
        await pumpEventQueue();
        expect(log, ['sentry 401', 'otel 401', 'body listened']);

        body.addBytes(32 * kib);
        await pumpEventQueue();
        expect(response, isNull); // 32 KiB: still reading, to judge it
        body.addBytes(33 * kib);
        await pumpEventQueue();
        await sent;
        expect(response, isNotNull); // 65 KiB: over the limit, handed on
        expect(response!.isBuffered, isFalse);
        expect(body.controller.isClosed, isFalse);
        expect(judgedBody, isNull);

        final bytes = response!.bytes();
        body.addBytes(kib);
        await body.controller.close();
        // Whole: the chunks read for the judge come first, then the rest.
        expect((await bytes).length, 66 * kib);
      },
    );

    test(
      'that renews: the refused body is read to its end before the request is sent again',
      () async {
        final refused = Body(log);
        addTearDown(refused.controller.close);
        final inner = FakeTransport((request, _) {
          final header = request.headers['x-fake-credential'] ?? '';
          if (header.startsWith('fake-1#')) return fakeResponse(200);
          return TransportResponse(
            statusCode: 401,
            headers: {'content-length': '${65 * kib}'},
            body: refused.stream,
          );
        });

        TransportResponse? response;
        final sent = chain(inner).session.send(get()).then((r) => response = r);
        await pumpEventQueue();
        expect(backend.renewals, 1);
        expect(log, ['sentry 401', 'otel 401', 'body listened']);
        refused.addBytes(65 * kib);
        await pumpEventQueue();
        // Renewed, but the second send waits for the end of the first answer's body.
        expect(inner.requests, hasLength(1));
        expect(response, isNull);

        await refused.controller.close();
        await sent;
        expect(inner.requests, hasLength(2));
        expect(response!.statusCode, 200);
      },
    );
  });
}
