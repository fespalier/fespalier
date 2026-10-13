import 'package:dio/dio.dart';

import '../errors.dart';

/// `DioException` to `CrateStackFailure` (since 0.10.0): the last reader in
/// `CrateStackErrors([readGenerated, DioFailures.read])`.
abstract final class DioFailures {
  /// The failure [error] means, or null when it is not a `DioException` this reader knows.
  ///
  /// Connection errors and timeouts are [CrateStackOffline], and so is a gateway's or a captive
  /// portal's page (`text/html`, `502`, `503`, `504`, `511` without a CrateStack envelope); a
  /// `cancel` is [CrateStackCancelled]. A response with a CrateStack envelope is classified by its
  /// status and code (`CrateStackFailure.fromEnvelope`), after the app's own reader had its turn.
  /// A bare `500` is [CrateStackUnavailable], not offline.
  static CrateStackFailure? read(Object error) {
    if (error is! DioException) return null;
    final type = error.type;
    if (type == DioExceptionType.cancel) return const CrateStackCancelled();
    if (type == DioExceptionType.connectionError ||
        type == DioExceptionType.connectionTimeout ||
        type == DioExceptionType.sendTimeout ||
        type == DioExceptionType.receiveTimeout) {
      return CrateStackOffline(error);
    }
    // A certificate that does not verify may be a captive portal or an attack: unknown, not offline.
    if (type == DioExceptionType.badCertificate) return null;
    final response = error.response;
    final status = response?.statusCode;
    if (response == null || status == null) return null;
    return CrateStackFailure.fromResponse(
      status: status,
      body: response.data,
      contentType: response.headers.value(Headers.contentTypeHeader),
      retryAfter: response.headers.value('retry-after') != null,
      cause: error,
    );
  }
}
