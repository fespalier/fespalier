// A response body that streams (server-sent events) through Dio on both sides of the transport
// seam, on the VM: DioTransport over an adapter whose body the test writes chunk by chunk, and a
// Dio over TransportAdapter over a FakeTransport whose body is a StreamController. Neither buffers
// a 2xx: the first chunk reaches the caller while the server is still sending. A caller that
// cancels its subscription does not end the server's stream on either side (Dio's response sink
// has no onCancel); the request's abortTrigger, or a CancelToken, does. (On the web, Dio's default
// adapter buffers; that is not a VM test's to see.) Plain test(), not testWidgets: Dio starts its
// interceptor chain with Timer.run.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final url = Uri.parse('https://api.example.com/events');

/// A body the test writes, counting whether it is still listened to.
final class Body {
  var cancelled = false;
  late final controller = StreamController<Uint8List>(
    onCancel: () => cancelled = true,
  );

  void add(String text) => controller.add(utf8.encode(text));
}

void main() {
  group('DioTransport over an adapter that streams', () {
    late Body body;
    late DioTransport transport;

    setUp(() {
      body = Body();
      addTearDown(() => body.controller.close());
      final adapter = FakeAdapter(
        (options, _) async => ResponseBody(
          body.controller.stream,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/event-stream'],
          },
        ),
      );
      transport = DioTransport(dioOver(adapter));
    });

    test('the first event arrives while the server sends', () async {
      final response = await transport.send(
        TransportRequest(method: 'GET', uri: url),
      );
      expect(response.statusCode, 200);
      expect(response.isBuffered, isFalse);
      expect(response.headers['content-type'], 'text/event-stream');

      final received = <String>[];
      final sub = response.body.map(utf8.decode).listen(received.add);
      body.add(': hi\n\n');
      body.add('data: 1\n\n');
      await pumpEventQueue();
      expect(received, [': hi\n\n', 'data: 1\n\n']);
      expect(body.controller.isClosed, isFalse);
      await sub.cancel();
    });

    // Dio wraps an adapter's body in a StreamController of its own (handleResponseStream, dio
    // 5.11.1) with no onCancel: a caller that cancels its subscription leaves the adapter's stream
    // read to its end. Only the request's abortTrigger (DioTransport's CancelToken) ends it. A
    // server-sent events client over DioTransport must abort, not just cancel.
    test('a cancel by the caller does not reach the server stream', () async {
      final response = await transport.send(
        TransportRequest(method: 'GET', uri: url),
      );
      final first = Completer<void>();
      final sub = response.body.listen((_) {
        if (!first.isCompleted) first.complete();
      });
      body.add('data: 1\n\n');
      await first.future;
      await sub.cancel();
      await pumpEventQueue();
      expect(body.cancelled, isFalse);
      expect(body.controller.hasListener, isTrue);
    });

    test('the abortTrigger does: the body ends with Dio\'s cancel', () async {
      final abort = Completer<void>();
      final response = await transport.send(
        TransportRequest(method: 'GET', uri: url, abortTrigger: abort.future),
      );
      final received = <String>[];
      Object? error;
      final done = Completer<void>();
      response.body
          .map(utf8.decode)
          .listen(
            received.add,
            onError: (Object e) => error = e,
            onDone: done.complete,
          );
      body.add('data: 1\n\n');
      await pumpEventQueue();
      expect(received, ['data: 1\n\n']);

      abort.complete();
      await done.future;
      expect(body.cancelled, isTrue);
      // Not a TransportFailure: an error inside a body is the transport's own.
      expect(error, isA<DioException>());
      expect((error! as DioException).type, DioExceptionType.cancel);
    });
  });

  group('a Dio over TransportAdapter over a transport that streams', () {
    test(
      'ResponseType.stream: the first event arrives while the server sends',
      () async {
        final body = StreamController<List<int>>();
        addTearDown(body.close);
        final dio = Dio()
          ..httpClientAdapter = TransportAdapter(
            FakeTransport(
              (request, _) => TransportResponse(
                statusCode: 200,
                headers: const {'content-type': 'text/event-stream'},
                body: body.stream,
              ),
            ),
          );

        final response = await dio.getUri<ResponseBody>(
          url,
          options: Options(responseType: ResponseType.stream),
        );
        final received = <String>[];
        final sub = response.data!.stream.map(utf8.decode).listen(received.add);
        body.add(utf8.encode('data: 1\n\n'));
        await pumpEventQueue();
        expect(received, ['data: 1\n\n']);
        expect(body.isClosed, isFalse);
        await sub.cancel();
      },
    );

    // The same Dio wrapper sits above TransportAdapter: a caller's cancel leaves the transport's
    // body read to its end; a CancelToken aborts it (TransportAdapter turns it into the request's
    // abortTrigger, which completes, and Dio cancels the adapter's stream).
    test(
      'a cancel by the caller does not reach the transport; a CancelToken does',
      () async {
        final bodies = <Body>[];
        final transport = FakeTransport((request, _) {
          final body = Body();
          bodies.add(body);
          addTearDown(body.controller.close);
          return TransportResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: body.controller.stream,
          );
        });
        final dio = Dio()..httpClientAdapter = TransportAdapter(transport);

        final first = await dio.getUri<ResponseBody>(
          url,
          options: Options(responseType: ResponseType.stream),
        );
        await first.data!.stream.listen((_) {}).cancel();
        await pumpEventQueue();
        expect(bodies[0].cancelled, isFalse);
        expect(transport.abortCount, 0);

        final token = CancelToken();
        final second = await dio.getUri<ResponseBody>(
          url,
          cancelToken: token,
          options: Options(responseType: ResponseType.stream),
        );
        final done = Completer<void>();
        second.data!.stream.listen(
          (_) {},
          onError: (Object _) {},
          onDone: done.complete,
        );
        token.cancel();
        await done.future;
        await pumpEventQueue();
        expect(bodies[1].cancelled, isTrue);
        expect(transport.requests[1].abortable, isTrue);
        expect(transport.abortCount, 1);
      },
    );
  });
}
