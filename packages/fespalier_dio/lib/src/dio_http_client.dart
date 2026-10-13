import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;

/// A [Dio] as a `package:http` client (since 0.15.0): everything that takes an `http.Client` can
/// send through the app's Dio, with its interceptors (a session, `WriteGuard`, a retrier), its
/// adapter and its base options.
///
/// ```dart
/// final client = ref.abortable(DioHttpClient(ref.watch(dio)));
/// ```
///
/// Behaviour:
///
/// * The body is streamed (`ResponseType.stream`) and every status is an answer, not an
///   exception (`validateStatus: (_) => true`): a 404 or a 500 comes back as a response, as
///   `package:http` clients do. An interceptor that rejects on a status still can.
/// * An `Abortable` request's `abortTrigger` cancels a `CancelToken`, through a side `then` (no
///   timer): the request fails with `http.RequestAbortedException`. Any other `DioException` of
///   type `cancel` is the same; every other failure is an `http.ClientException`.
/// * [close] does nothing: the Dio belongs to whoever made it (usually a provider that closes it).
///
/// A request's `followRedirects`, `maxRedirects` and `persistentConnection` are passed on; the
/// Dio's own base URL does not apply, because an `http.BaseRequest` always has an absolute URL.
final class DioHttpClient extends http.BaseClient {
  /// A client that sends through [dio].
  DioHttpClient(this.dio);

  /// The Dio every request goes through.
  final Dio dio;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final token = CancelToken();
    final Object asObject = request;
    if (asObject is http.Abortable) {
      final trigger = asObject.abortTrigger;
      if (trigger != null) {
        // A side `then`: it starts no timer, and cancelling a finished request does nothing.
        unawaited(
          trigger.then<void>((_) {
            if (!token.isCancelled) token.cancel('aborted by abortTrigger');
          }),
        );
      }
    }

    final headers = Map<String, Object?>.of(request.headers);
    final length = request.contentLength;
    final Stream<Uint8List>? body;
    if (length == 0) {
      body = null;
    } else {
      body = request.finalize().map(Uint8List.fromList);
      if (length != null) {
        headers.removeWhere((k, _) => k.toLowerCase() == 'content-length');
        headers[Headers.contentLengthHeader] = '$length';
      }
    }

    final Response<ResponseBody> response;
    try {
      response = await dio.requestUri<ResponseBody>(
        request.url,
        data: body,
        cancelToken: token,
        options: Options(
          method: request.method,
          headers: headers,
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          followRedirects: request.followRedirects,
          maxRedirects: request.maxRedirects,
          persistentConnection: request.persistentConnection,
        ),
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        throw http.RequestAbortedException(request.url);
      }
      throw http.ClientException(
        'fespalier_dio: ${error.type.name}${error.message == null ? '' : ': ${error.message}'}',
        request.url,
      );
    }

    final answer = response.data;
    if (answer == null) {
      throw http.ClientException(
        'fespalier_dio: the response has no body stream',
        request.url,
      );
    }
    return http.StreamedResponse(
      answer.stream,
      response.statusCode ?? answer.statusCode,
      contentLength: answer.contentLength < 0 ? null : answer.contentLength,
      request: request,
      headers: {
        for (final entry in response.headers.map.entries)
          entry.key: entry.value.join(', '),
      },
      isRedirect: answer.isRedirect,
      persistentConnection: request.persistentConnection,
      reasonPhrase: response.statusMessage,
    );
  }

  /// The Dio belongs to whoever made it (usually a provider that closes it).
  @override
  void close() {}
}
