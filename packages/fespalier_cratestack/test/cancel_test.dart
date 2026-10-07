// ref.cancellable: the generated client's options carry no cancel token, so it travels in the zone.
// A plain test(): Dio starts its chain with Timer.run, which testWidgets would report as pending.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/dio.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart'
    show CrateStackOffline;
import 'package:flutter_test/flutter_test.dart';

/// An adapter that never answers until [release] is called or the request is cancelled.
final class HangingAdapter implements HttpClientAdapter {
  final started = <Completer<void>>[];
  final seen = <RequestOptions>[];
  final _release = Completer<void>();

  /// Answers every hanging request.
  void release() => _release.complete();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    final begun = Completer<void>()..complete();
    started.add(begun);
    final cancelled = cancelFuture == null
        ? Completer<bool>().future
        : cancelFuture.then((_) => true);
    final answered = await Future.any([
      _release.future.then((_) => false),
      cancelled,
    ]);
    if (answered) {
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: 'cancelled',
      );
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// An adapter that answers every request with a web page, like a captive portal.
final class PageAdapter implements HttpClientAdapter {
  PageAdapter(this.contentType, this.body);
  final String contentType;
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    body,
    200,
    headers: {
      Headers.contentTypeHeader: [contentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

Dio dioWith(HangingAdapter adapter) => Dio()
  ..httpClientAdapter = adapter
  ..interceptors.add(const CrateStackCancelInterceptor());

Matcher cancelled() => throwsA(
  isA<DioException>().having((e) => e.type, 'type', DioExceptionType.cancel),
);

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'a request started in ref.cancellable is cancelled when the container is disposed',
    () async {
      final adapter = HangingAdapter();
      final dio = dioWith(adapter);
      final container = ProviderContainer();
      final read = Provider<Future<Response<Object?>>>(
        (ref) => ref.cancellable(() => dio.get<Object?>('/orders')),
      );
      final request = container.read(read);
      final expectation = expectLater(request, cancelled());
      while (adapter.seen.isEmpty) {
        await settle();
      }
      // The zone reached the interceptor: the request carries the provider's token.
      expect(adapter.seen.single.cancelToken, isNotNull);
      expect(adapter.seen.single.cancelToken!.isCancelled, isFalse);
      container.dispose();
      await expectation;
      expect(adapter.seen.single.cancelToken!.isCancelled, isTrue);
    },
  );

  test('a rebuild cancels the request of the build it replaces', () async {
    final adapter = HangingAdapter();
    final dio = dioWith(adapter);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final read = Provider<Future<Response<Object?>>>(
      (ref) => ref.cancellable(() => dio.get<Object?>('/orders')),
    );
    final first = container.read(read);
    final expectation = expectLater(first, cancelled());
    while (adapter.seen.isEmpty) {
      await settle();
    }
    container.invalidate(read);
    container.read(read).ignore();
    await expectation;
    adapter.release();
  });

  test('every request the body makes shares the provider\'s token', () async {
    final adapter = HangingAdapter();
    final dio = dioWith(adapter);
    final container = ProviderContainer();
    final read = Provider<Future<List<Response<Object?>>>>(
      (ref) => ref.cancellable(
        () => Future.wait([dio.get<Object?>('/a'), dio.get<Object?>('/b')]),
      ),
    );
    final both = container.read(read);
    final expectation = expectLater(both, cancelled());
    while (adapter.seen.length < 2) {
      await settle();
    }
    expect(adapter.seen[0].cancelToken, same(adapter.seen[1].cancelToken));
    container.dispose();
    await expectation;
  });

  test('a request outside ref.cancellable is untouched', () async {
    final adapter = HangingAdapter();
    final dio = dioWith(adapter);
    final container = ProviderContainer();
    final outside = dio.get<Object?>('/free');
    while (adapter.seen.isEmpty) {
      await settle();
    }
    expect(adapter.seen.single.cancelToken, isNull);
    container.dispose();
    adapter.release();
    expect((await outside).statusCode, 200);
  });

  test('a token the request brought is kept', () async {
    final adapter = HangingAdapter();
    final dio = dioWith(adapter);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final own = CancelToken();
    final read = Provider<Future<Response<Object?>>>(
      (ref) => ref.cancellable(() => dio.get<Object?>('/x', cancelToken: own)),
    );
    container.read(read).ignore();
    while (adapter.seen.isEmpty) {
      await settle();
    }
    expect(adapter.seen.single.cancelToken, same(own));
    adapter.release();
  });

  test('cancellable returns the body\'s very Future', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final future = Future<int>.value(3);
    final read = Provider<Future<int>>((ref) => ref.cancellable(() => future));
    expect(container.read(read), same(future));
  });

  test('on a provider that is gone, the token is already cancelled', () async {
    final adapter = HangingAdapter();
    final dio = dioWith(adapter);
    final container = ProviderContainer();
    final read = Provider<Ref>((ref) => ref);
    final ref = container.read(read);
    container.dispose();
    final request = ref.cancellable(() => dio.get<Object?>('/gone'));
    await expectLater(request, cancelled());
  });

  group('CrateStackPortalInterceptor', () {
    Future<Object?> call(Dio dio) => dio
        .get<Object?>('/x')
        .then<Object?>((r) => r, onError: (Object e) => e);

    test(
      'a web page with a 200 becomes an error that reads as offline',
      () async {
        final dio = Dio()
          ..httpClientAdapter = PageAdapter(
            'text/html; charset=utf-8',
            '<html>sign in</html>',
          )
          ..interceptors.add(const CrateStackPortalInterceptor());
        final out = await call(dio);
        expect(out, isA<DioException>());
        expect(
          DioFailures.read(out! as DioException),
          isA<CrateStackOffline>(),
        );
      },
    );

    test(
      'without it the page is a success that Dio hands to the client',
      () async {
        final dio = Dio()
          ..httpClientAdapter = PageAdapter(
            'text/html',
            '<html>sign in</html>',
          );
        expect(await call(dio), isA<Response<Object?>>());
      },
    );

    test('a JSON answer passes through untouched', () async {
      final dio = Dio()
        ..httpClientAdapter = PageAdapter('application/json', '{"a":1}')
        ..interceptors.add(const CrateStackPortalInterceptor());
      final out = await call(dio);
      expect(out, isA<Response<Object?>>());
      expect((out! as Response<Object?>).data, {'a': 1});
    });
  });
}
