// package:http: ref.abortTrigger() and ref.abortable(client). (The write guard under a RetryClient
// is transport_client_test.dart.) A MockClient does not honour an abort trigger by itself ("it is
// the handler's responsibility"), so the handlers here race the trigger the way a real client does.
import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart'
    show FutureProvider, Provider, ProviderContainer, ProviderSubscription, Ref;
import 'package:fespalier_http/fespalier_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A client that counts how often it was closed.
final class CountingClient extends http.BaseClient {
  CountingClient(this.inner);

  final http.Client inner;
  int closed = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);

  @override
  void close() => closed++;
}

/// A handler that holds the request until its abort trigger fires, then fails like a real client.
Future<http.StreamedResponse> holdUntilAborted(
  http.BaseRequest request,
  http.ByteStream body,
) async {
  final trigger = (request as http.Abortable).abortTrigger!;
  await trigger;
  throw http.RequestAbortedException(request.url);
}

http.StreamedResponse streamed(int status, {http.BaseRequest? request}) =>
    http.StreamedResponse(
      const Stream<List<int>>.empty(),
      status,
      request: request,
    );

final url = Uri.parse('https://api.example.com/items');

void main() {
  group('ref.abortTrigger()', () {
    test('completes when the provider is disposed, not before', () async {
      final fired = Completer<void>();
      final reached = Completer<void>();
      final load = FutureProvider.autoDispose<void>((ref) async {
        unawaited(ref.abortTrigger().then(fired.complete));
        reached.complete();
        await Completer<void>().future;
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final subscription = container.listen(load, (_, _) {});
      await reached.future;
      await Future<void>.value();
      expect(fired.isCompleted, isFalse);

      subscription.close();
      await container.pump();

      await expectLater(fired.future, completes);
    });

    test(
      'is already complete after the provider is gone, and for a stale ref',
      () async {
        final refs = <Ref>[];
        final load = FutureProvider.autoDispose<int>((ref) {
          refs.add(ref);
          return refs.length;
        });
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.listen(load, (_, _) {});
        container.invalidate(load);
        expect(await container.read(load.future), 2);

        expect(refs[0].mounted, isFalse);
        await expectLater(refs[0].abortTrigger(), completes);
        var fired = false;
        unawaited(refs[1].abortTrigger().then((_) => fired = true));
        await Future<void>.value();
        expect(fired, isFalse);
      },
    );

    test(
      'a rebuild fires the old trigger and gives the new build one of its own',
      () async {
        final fired = <int>[];
        final firstFired = Completer<void>();
        var builds = 0;
        final load = FutureProvider.autoDispose<int>((ref) {
          final index = builds++;
          unawaited(
            ref.abortTrigger().then((_) {
              fired.add(index);
              if (index == 0) firstFired.complete();
            }),
          );
          return index;
        });
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.listen(load, (_, _) {});
        container.invalidate(load);
        expect(await container.read(load.future), 1);
        await firstFired.future;

        expect(fired, [0]);
      },
    );

    test('is the abortTrigger of an AbortableRequest', () async {
      final seen = Completer<http.BaseRequest>();
      final client = MockClient.streaming((request, body) async {
        seen.complete(request);
        return holdUntilAborted(request, body);
      });
      final outcome = Completer<Object>();
      final load = FutureProvider.autoDispose<void>((ref) async {
        final request = http.AbortableRequest(
          'GET',
          url,
          abortTrigger: ref.abortTrigger(),
        );
        try {
          await client.send(request);
        } on Object catch (error) {
          outcome.complete(error);
        }
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final subscription = container.listen(load, (_, _) {});
      await seen.future;

      subscription.close();
      await container.pump();

      expect(await outcome.future, isA<http.RequestAbortedException>());
    });
  });

  group('ref.abortable(client)', () {
    test(
      'disposing the provider aborts a request in flight, and does not close the client',
      () async {
        final inner = CountingClient(MockClient.streaming(holdUntilAborted));
        final started = Completer<void>();
        final outcome = Completer<Object>();
        late http.Client wrapped;
        final load = FutureProvider.autoDispose<void>((ref) async {
          wrapped = ref.abortable(inner);
          started.complete();
          try {
            await wrapped.get(url);
          } on Object catch (error) {
            outcome.complete(error);
            rethrow; // as a data.dart would
          }
        });
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final subscription = container.listen(load, (_, _) {});
        await started.future;

        subscription.close();
        await container.pump();

        final error = await outcome.future;
        expect(error, isA<http.RequestAbortedException>());
        expect('$error', contains('Request aborted by `abortTrigger`'));
        wrapped.close();
        expect(
          inner.closed,
          0,
          reason: 'closing the wrapper must not close the client under it',
        );
      },
    );

    test(
      'a rebuild aborts the old build\'s request, and the new one is answered',
      () async {
        var sends = 0;
        final firstOutcome = Completer<Object>();
        final client = MockClient.streaming((request, body) async {
          sends++;
          if (sends == 1) return holdUntilAborted(request, body);
          return streamed(200);
        });
        var builds = 0;
        final load = FutureProvider.autoDispose<int>((ref) async {
          final build = ++builds;
          try {
            return (await ref.abortable(client).get(url)).statusCode;
          } on Object catch (error) {
            if (build == 1) firstOutcome.complete(error);
            rethrow;
          }
        });
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.listen(load, (_, _) {});
        await Future<void>.value();
        container.invalidate(load);

        expect(await firstOutcome.future, isA<http.RequestAbortedException>());
        expect(await container.read(load.future), 200);
      },
    );

    test('a request after the provider is gone is aborted at once', () async {
      final refs = <Ref>[];
      final load = FutureProvider.autoDispose<int>((ref) {
        refs.add(ref);
        return 0;
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final subscription = container.listen(load, (_, _) {});
      subscription.close();
      await container.pump();
      var reachedNetwork = false;
      final client = refs.single.abortable(
        MockClient.streaming((request, body) async {
          reachedNetwork = true;
          return holdUntilAborted(request, body);
        }),
      );

      await expectLater(
        client.get(url),
        throwsA(isA<http.RequestAbortedException>()),
      );
      expect(
        reachedNetwork,
        isTrue,
        reason: 'the handler saw the request, with its trigger already fired',
      );
    });

    group('each kind of request is sent as its Abortable twin', () {
      late http.Client wrapped;
      late List<http.BaseRequest> seen;
      late List<List<int>> bodies;
      late ProviderContainer container;
      late ProviderSubscription<http.Client> subscription;

      setUp(() {
        seen = [];
        bodies = [];
        final inner = MockClient.streaming((request, body) async {
          seen.add(request);
          bodies.add(await body.toBytes());
          return streamed(200);
        });
        final provider = Provider.autoDispose<http.Client>(
          (ref) => ref.abortable(inner),
        );
        container = ProviderContainer();
        subscription = container.listen(provider, (_, _) {});
        wrapped = subscription.read();
        addTearDown(container.dispose);
      });

      Future<void> disposeAndAssertFired() async {
        final abortTrigger = (seen.single as http.Abortable).abortTrigger!;
        final fired = Completer<void>();
        unawaited(abortTrigger.then(fired.complete));
        await Future<void>.value();
        expect(fired.isCompleted, isFalse);

        subscription.close();
        await container.pump();

        await expectLater(fired.future, completes);
      }

      test('Request: method, url, headers, body and settings', () async {
        final request = http.Request('POST', url)
          ..headers['x-one'] = '1'
          ..headers['content-type'] = 'application/json; charset=utf-8'
          ..bodyBytes = utf8.encode('{"é":1}')
          ..followRedirects = false
          ..maxRedirects = 2
          ..persistentConnection = false;

        await wrapped.send(request);

        final sent = seen.single;
        expect(sent, isA<http.AbortableRequest>());
        expect(sent.method, 'POST');
        expect(sent.url, url);
        expect(sent.headers['x-one'], '1');
        expect(sent.headers['Content-Type'], 'application/json; charset=utf-8');
        expect(sent.followRedirects, isFalse);
        expect(sent.maxRedirects, 2);
        expect(sent.persistentConnection, isFalse);
        expect(utf8.decode(bodies.single), '{"é":1}');
        await disposeAndAssertFired();
      });

      test(
        'the convenience methods (get, post with a body) go through it',
        () async {
          await wrapped.post(url, headers: {'x-a': 'b'}, body: 'name=ada');

          expect(seen.single, isA<http.AbortableRequest>());
          expect(seen.single.headers['x-a'], 'b');
          expect(utf8.decode(bodies.single), 'name=ada');
          await disposeAndAssertFired();
        },
      );

      test('MultipartRequest: fields and files', () async {
        final request = http.MultipartRequest('POST', url)
          ..fields['name'] = 'ada'
          ..files.add(
            http.MultipartFile.fromString('note', 'hello', filename: 'n.txt'),
          );

        await wrapped.send(request);

        final sent = seen.single as http.MultipartRequest;
        expect(sent, isA<http.AbortableMultipartRequest>());
        expect(sent.fields, {'name': 'ada'});
        expect(sent.files.single.filename, 'n.txt');
        final body = utf8.decode(bodies.single);
        expect(body, contains('name="name"'));
        expect(body, contains('ada'));
        expect(body, contains('hello'));
        await disposeAndAssertFired();
      });

      test(
        'StreamedRequest: the body written to the original is piped',
        () async {
          final request = http.StreamedRequest('PUT', url)..contentLength = 6;

          final response = wrapped.send(request);
          request.sink.add([1, 2, 3]);
          request.sink.add([4, 5, 6]);
          unawaited(request.sink.close());
          await response;

          final sent = seen.single;
          expect(sent, isA<http.AbortableStreamedRequest>());
          expect(sent.contentLength, 6);
          expect(bodies.single, [1, 2, 3, 4, 5, 6]);
          await disposeAndAssertFired();
        },
      );

      test(
        'a request with a trigger of its own is aborted by whichever fires first',
        () async {
          final own = Completer<void>();

          await wrapped.send(
            http.AbortableRequest('GET', url, abortTrigger: own.future),
          );

          final abortTrigger = (seen.single as http.Abortable).abortTrigger!;
          final fired = Completer<void>();
          unawaited(abortTrigger.then(fired.complete));
          await Future<void>.value();
          expect(fired.isCompleted, isFalse);

          own.complete();
          await expectLater(fired.future, completes);
        },
      );

      test(
        'the provider\'s trigger aborts a request that has one of its own',
        () async {
          final own = Completer<void>();
          await wrapped.send(
            http.AbortableRequest('GET', url, abortTrigger: own.future),
          );

          await disposeAndAssertFired();
          expect(own.isCompleted, isFalse);
        },
      );
    });
  });
}
