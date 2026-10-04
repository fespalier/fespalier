import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart' show Ref;

/// M-D3: the reason a [CancelToken] of [FespalierDioRef.cancelToken] is cancelled with, which is
/// the `DioException.error` of the request it cancelled.
const String cancelledWithProviderMessage =
    'fespalier_dio: the provider that started this request was disposed';

/// Cancelling a `data.dart`'s requests with its provider (since 0.9.0).
extension FespalierDioRef on Ref {
  /// A token cancelled when this provider is disposed or rebuilt (`ref.onDispose`). Call it before
  /// the first `await`; after the provider is gone it returns a token that is already cancelled.
  ///
  /// Both dispose and rebuild discard the result of the build that asked, so a request that is
  /// still in flight has nobody to answer to. Give the token to every request of the build
  /// (`dio.get(url, cancelToken: token)`): a request that follows a refresh or a retry keeps it,
  /// because the retry sends the same options. A cancelled request fails with a
  /// `DioException` of type `cancel` whose `error` is the text above, after the provider is gone,
  /// so nothing reads it.
  ///
  /// It starts no timer and listens to nothing: the cancellation runs inside `dispose`.
  CancelToken cancelToken() {
    final token = CancelToken();
    // `onDispose` on a Ref that is gone throws: the answer is the token that is already spent.
    if (!mounted) return token..cancel(cancelledWithProviderMessage);
    onDispose(() => token.cancel(cancelledWithProviderMessage));
    return token;
  }
}
