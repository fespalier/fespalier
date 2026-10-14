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
/// * The response body is streamed (`ResponseType.stream`) and every status is an answer, not an
///   exception (`validateStatus: (_) => true`): a 404 or a 500 comes back as a response, as
///   `package:http` clients do. An interceptor that rejects on a status still can.
/// * A request made of bytes (an `http.Request`, which `get`, `post`, `put`, `patch` and `delete`
///   make) sends its body as bytes, so an interceptor that sends the same request again (a
///   session refreshing after a 401) can: the body goes out whole a second time. A streamed or
///   multipart request streams its body, which can be read once, so it cannot be sent again (since
///   0.16.0; before it, every body streamed and no request with a body could be replayed).
/// * An `Abortable` request's `abortTrigger` cancels a `CancelToken`, through a side `then` (no
///   timer): the request fails with `http.RequestAbortedException`. Any other `DioException` of
///   type `cancel` is the same; every other failure is an `http.ClientException` whose message
///   names the type and Dio's message or, when it has none, the error an interceptor or adapter
///   threw (the cause, since 0.16.0).
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
    final Object? body;
    if (length == 0) {
      body = null;
    } else {
      if (request is http.Request) {
        // A request made of bytes (`get`, `post`, `put`, `patch` and `delete` make one) goes as
        // bytes: an interceptor that sends the same `RequestOptions` again (a session, after a
        // 401 and a refresh) sends the whole body again. Finalized, as every client does, so
        // that the request cannot be sent twice by the caller.
        request.finalize();
        body = request.bodyBytes;
      } else {
        // A streamed or multipart body can be read once: it is streamed, and cannot be replayed.
        body = request.finalize().map(Uint8List.fromList);
      }
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
      // What Dio says, or else what an interceptor or an adapter threw (an `unknown` failure
      // has no message): the cause is the part that tells what went wrong.
      final reason = error.message ?? error.error;
      throw http.ClientException(
        'fespalier_dio: ${error.type.name}${reason == null ? '' : ': $reason'}',
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
