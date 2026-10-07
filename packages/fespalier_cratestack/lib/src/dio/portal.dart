import 'package:dio/dio.dart';

/// Turns a web page where an answer was expected into an error `DioFailures.read` calls offline
/// (since 0.10.0).
///
/// Dio does not throw on a `2xx`, so a captive portal's or a gateway's HTML page with a `200` reaches
/// the generated client, which cannot decode it and throws something no reader knows. This
/// interceptor rejects a response of type `text/html` as a `badResponse` instead, and
/// `DioFailures.read` reads that as `CrateStackOffline`: nobody that knows CrateStack answered.
/// Add it to the Dio the generated client uses. It starts no timer and listens to nothing.
final class CrateStackPortalInterceptor extends Interceptor {
  /// The interceptor.
  const CrateStackPortalInterceptor();

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final type = response.headers.value(Headers.contentTypeHeader);
    if (type != null && type.toLowerCase().contains('text/html')) {
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
        ),
        true,
      );
      return;
    }
    handler.next(response);
  }
}
