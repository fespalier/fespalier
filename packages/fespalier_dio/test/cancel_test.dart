// ref.cancelToken(): a request lives as long as the provider build that made it. Plain test(), not
// testWidgets: Dio starts its interceptor chain with Timer.run, which only a real event loop runs.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart'
    show FutureProvider, ProviderContainer, Ref;
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const reason =
    'fespalier_dio: the provider that started this request was disposed';

void main() {
  test(
    'closing the last listener cancels the request, with the reason',
    () async {
      final started = Completer<void>();
      final adapterSawCancel = Completer<void>();
      final outcome = Completer<DioException>();
      final adapter = FakeAdapter((options, cancelFuture) {
        started.complete();
        unawaited(cancelFuture?.then(adapterSawCancel.complete));
        return Completer<ResponseBody>().future; // never answers
      });
      final dio = dioOver(adapter);
      final load = FutureProvider.autoDispose<String>((ref) async {
        final token = ref.cancelToken();
        try {
          final response = await dio.get<String>(
            'https://api.example.com/items',
            cancelToken: token,
          );
          return response.data!;
        } on DioException catch (error) {
          outcome.complete(error);
          rethrow; // as a data.dart would: nobody reads it, and nothing may be unhandled
        }
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final subscription = container.listen(load, (_, _) {});
      await started.future;
      expect(adapter.sent, 1);

      subscription.close();
      await container.pump();

      final error = await outcome.future;
      expect(error.type, DioExceptionType.cancel);
      expect(error.error, reason);
      await adapterSawCancel.future;
    },
  );

  test(
    'a rebuild cancels the old request and the new build gets a token of its own',
    () async {
      final tokens = <CancelToken>[];
      final firstStarted = Completer<void>();
      final firstOutcome = Completer<DioException>();
      final adapter = FakeAdapter((options, cancelFuture) async {
        if (options.path.endsWith('/first')) {
          firstStarted.complete();
          return Completer<ResponseBody>().future;
        }
        return jsonAnswer({'name': 'second'}, 200);
      });
      final dio = dioOver(adapter);
      var builds = 0;
      final load = FutureProvider.autoDispose<String>((ref) async {
        final token = ref.cancelToken();
        tokens.add(token);
        final build = ++builds;
        try {
          final response = await dio.get<Map<String, Object?>>(
            'https://api.example.com/${build == 1 ? 'first' : 'second'}',
            cancelToken: token,
          );
          return response.data!['name']! as String;
        } on DioException catch (error) {
          if (build == 1) firstOutcome.complete(error);
          rethrow;
        }
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(load, (_, _) {});
      await firstStarted.future;

      container.invalidate(load);

      expect((await firstOutcome.future).error, reason);
      expect(await container.read(load.future), 'second');
      expect(tokens, hasLength(2));
      expect(tokens[0].isCancelled, isTrue);
      expect(tokens[1].isCancelled, isFalse);
      expect(identical(tokens[0], tokens[1]), isFalse);
    },
  );

  test('one token serves every request of a build', () async {
    final seen = <CancelToken?>[];
    final bothSent = Completer<void>();
    final bothFailed = Completer<void>();
    final adapter = FakeAdapter((options, cancelFuture) {
      seen.add(options.cancelToken);
      if (seen.length == 2) bothSent.complete();
      return Completer<ResponseBody>().future;
    });
    final dio = dioOver(adapter);
    final failures = <DioException>[];
    final load = FutureProvider.autoDispose<void>((ref) async {
      final token = ref.cancelToken();
      Future<void> get(String path) => dio
          .get<void>('https://api.example.com/$path', cancelToken: token)
          .then<void>(
            (_) {},
            onError: (Object error) {
              failures.add(error as DioException);
              if (failures.length == 2) bothFailed.complete();
            },
          );
      await Future.wait([get('a'), get('b')]);
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final subscription = container.listen(load, (_, _) {});
    await bothSent.future;
    expect(identical(seen[0], seen[1]), isTrue);

    subscription.close();
    await container.pump();
    await bothFailed.future;

    expect(failures.map((e) => e.type), everyElement(DioExceptionType.cancel));
    expect(failures.map((e) => e.error), everyElement(reason));
  });

  test(
    'after the provider is gone the token comes back already cancelled',
    () async {
      late Ref captured;
      final load = FutureProvider.autoDispose<int>((ref) {
        captured = ref;
        return 1;
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final subscription = container.listen(load, (_, _) {});
      subscription.close();
      await container.pump();
      expect(captured.mounted, isFalse);

      // `onDispose` on a ref that is gone would throw: the token is made already spent instead.
      final token = captured.cancelToken();

      expect(token.isCancelled, isTrue);
      expect(token.cancelError?.type, DioExceptionType.cancel);
      expect(token.cancelError?.error, reason);
    },
  );

  test('a stale ref of a rebuilt provider also gets a spent token', () async {
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
    expect(refs[0].cancelToken().isCancelled, isTrue);
    expect(refs[1].cancelToken().isCancelled, isFalse);
  });

  test(
    'a request that already finished is not touched by the dispose',
    () async {
      final adapter = FakeAdapter((options, cancelFuture) async {
        return jsonAnswer({'name': 'ok'}, 200);
      });
      final dio = dioOver(adapter);
      late CancelToken token;
      final load = FutureProvider.autoDispose<String>((ref) async {
        token = ref.cancelToken();
        final response = await dio.get<Map<String, Object?>>(
          'https://api.example.com/items',
          cancelToken: token,
        );
        return response.data!['name']! as String;
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final subscription = container.listen(load, (_, _) {});
      expect(await container.read(load.future), 'ok');

      subscription.close();
      await container.pump();

      // Cancelling a token nobody waits on is not an error and not a warning.
      expect(token.isCancelled, isTrue);
    },
  );
}
