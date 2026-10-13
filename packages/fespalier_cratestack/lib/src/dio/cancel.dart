import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart' show Ref;
import 'package:fespalier_dio/fespalier_dio.dart' show FespalierDioRef;

/// The zone value that carries the token of the provider running [CrateStackCancelRef.cancellable].
const Symbol _tokenKey = #fespalierCratestackCancelToken;

/// Cancelling a read's requests with its provider, through a generated client (since 0.10.0).
extension CrateStackCancelRef on Ref {
  /// Runs [body] with this provider's cancel token (`ref.cancelToken()` of fespalier_dio) in the
  /// zone, so every Dio request [body] makes through a client with [CrateStackCancelInterceptor]
  /// is cancelled when the provider is disposed or rebuilt.
  ///
  /// The generated options carry no cancel token, which is why the token travels in a zone value.
  /// The body must be only the client call: read or watch other providers **before** `cancellable`,
  /// not inside it. A provider built inside the body runs in the same zone, so its own requests
  /// would take this provider's token and be cancelled with it.
  ///
  /// Call it before the first `await` of the provider. Returns [body]'s very `Future`, and starts
  /// no timer.
  Future<T> cancellable<T>(Future<T> Function() body) {
    final token = cancelToken();
    return runZoned(body, zoneValues: {_tokenKey: token});
  }
}

/// Sets `options.cancelToken` from the zone when the request has none.
///
/// Add it to the Dio the generated adapter uses, then `WriteGuard.install(dio)` last, as
/// fespalier_dio says. It starts no timer and listens to nothing.
final class CrateStackCancelInterceptor extends Interceptor {
  /// The interceptor.
  const CrateStackCancelInterceptor();

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.cancelToken == null) {
      final token = Zone.current[_tokenKey];
      if (token is CancelToken) options.cancelToken = token;
    }
    handler.next(options);
  }
}
