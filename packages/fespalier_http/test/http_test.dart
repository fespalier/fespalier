// package:http: ref.abortTrigger() and ref.abortable(client), and WriteGuardClient under a
// RetryClient. A MockClient does not honour an abort trigger by itself ("it is the handler's
// responsibility"), so the handlers here race the trigger the way a real client does.
import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart'
    show FutureProvider, Provider, ProviderContainer, ProviderSubscription, Ref;
import 'package:fespalier_http/fespalier_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
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

/// A client that returns what a function makes: no MockClient, which wraps every response in a
/// new object.
final class _Fixed extends http.BaseClient {
  _Fixed(this.make);

  final Future<http.StreamedResponse> Function() make;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => make();
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

  group('WriteGuardClient under a RetryClient', () {
    RetryClient retrying(http.Client inner) => RetryClient(
      WriteGuardClient(inner),
      when: WriteGuardClient.readsOnly(),
      whenError: WriteGuardClient.readErrorsOnly((error, stackTrace) => true),
      delay: (_) => Duration.zero,
    );

    test('a POST that gets a 503 is sent once; a GET is retried', () async {
      final sent = <String>[];
      final client = retrying(
        MockClient((request) async {
          sent.add(request.method);
          return http.Response('', sent.length < 2 ? 503 : 200);
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
          MockClient((request) async {
            sent++;
            return http.Response('', 503);
          }),
        );
        final response = await client.send(http.Request(method, url));

        expect(response.statusCode, 503);
        expect(sent, 1, reason: method);
      }
      for (final method in ['GET', 'HEAD', 'OPTIONS']) {
        var sent = 0;
        final client = retrying(
          MockClient((request) async {
            sent++;
            return http.Response('', sent < 3 ? 503 : 200);
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
        MockClient((request) async {
          sent++;
          return http.Response('', sent < 2 ? 503 : 200);
        }),
      );

      final response = await client.post(
        url,
        headers: {'Idempotency-Key': 'k-1'},
      );

      expect(response.statusCode, 200);
      expect(sent, 2);
    });

    test('a write that throws is not retried, a read that throws is', () async {
      var sent = 0;
      final client = retrying(
        MockClient((request) async {
          sent++;
          if (sent < 2) throw http.ClientException('offline');
          return http.Response('', 200);
        }),
      );

      await expectLater(client.post(url), throwsA(isA<http.ClientException>()));
      expect(sent, 1);

      sent = 0;
      expect((await client.get(url)).statusCode, 200);
      expect(sent, 2);
    });

    test(
      'a write whose answer does not say which request it answers is still a write',
      () async {
        // MockClient's Response has no `request`, which is what real clients always set.
        var sent = 0;
        final client = retrying(
          MockClient.streaming((request, body) async {
            sent++;
            return streamed(503); // request: null
          }),
        );

        final response = await client.send(http.Request('DELETE', url));

        expect(response.request, isNull);
        expect(response.statusCode, 503);
        expect(sent, 1);
      },
    );

    test(
      'the response and the error are the very objects the inner client made',
      () async {
        final answer = streamed(200);
        final guard = WriteGuardClient(_Fixed(() async => answer));
        expect(
          identical(await guard.send(http.Request('POST', url)), answer),
          isTrue,
        );

        final failure = http.ClientException('boom');
        final failing = WriteGuardClient(_Fixed(() async => throw failure));
        Object? thrown;
        try {
          await failing.send(http.Request('POST', url));
        } on Object catch (error) {
          thrown = error;
        }
        expect(identical(thrown, failure), isTrue);
      },
    );

    test(
      'readsOnly takes the rule of your own, and the errors of a read go to yours',
      () async {
        final guard = WriteGuardClient(
          MockClient((request) async => http.Response('', 429)),
        );
        final read = await guard.send(http.Request('GET', url));
        final write = await guard.send(http.Request('POST', url));

        final on429 = WriteGuardClient.readsOnly(
          (response) => response.statusCode == 429,
        );
        expect(on429(read), isTrue);
        expect(on429(write), isFalse);
        expect(WriteGuardClient.readsOnly()(read), isFalse); // 429 is not 503
        expect(WriteGuardClient.retryOn503(streamed(503)), isTrue);
        expect(WriteGuardClient.retryOn503(streamed(200)), isFalse);

        var asked = 0;
        final onError = WriteGuardClient.readErrorsOnly((error, stackTrace) {
          asked++;
          return true;
        });
        expect(
          onError(StateError('x'), StackTrace.empty),
          isTrue,
        ); // never went through a guard
        expect(asked, 1);
      },
    );

    test('isWrite is the WriteGuard rule on a request', () {
      expect(WriteGuardClient.isWrite(http.Request('GET', url)), isFalse);
      expect(WriteGuardClient.isWrite(http.Request('post', url)), isTrue);
      expect(
        WriteGuardClient.isWrite(
          http.Request('POST', url)..headers['idempotency-key'] = 'k',
        ),
        isFalse,
      );
    });

    test('close closes the client under it', () {
      final inner = CountingClient(
        MockClient((request) async => http.Response('', 200)),
      );
      WriteGuardClient(inner).close();
      expect(inner.closed, 1);
    });

    test(
      'an aborted request is not retried, and is not a failed write',
      () async {
        var sent = 0;
        final abort = Completer<void>();
        final client = retrying(
          MockClient.streaming((request, body) async {
            sent++;
            throw http.RequestAbortedException(request.url);
          }),
        );

        await expectLater(
          client.send(
            http.AbortableRequest('GET', url, abortTrigger: abort.future),
          ),
          throwsA(isA<http.RequestAbortedException>()),
        );
        expect(sent, 1);
      },
    );
  });
}
