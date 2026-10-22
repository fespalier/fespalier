import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

/// What a Dio call threw, as the transport's own errors (since 0.21.0), for a reader that must
/// not see Dio types: `fespalier_cratestack`'s `TransportFailures.read` classifies a
/// `TransportFailure` or a `TransportStatusError` and nothing of Dio.
///
/// ```dart
/// CrateStackErrors([readShopError, (e) => TransportFailures.read(DioErrors.toTransport(e))])
/// ```
abstract final class DioErrors {
  /// [error] as a transport error:
  ///
  /// * a `DioException` whose cause (`error`) is a [TransportFailure] (what `TransportAdapter`
  ///   puts there) is that failure, the very object;
  /// * a `DioException` of type `cancel` is a [TransportAborted];
  /// * a `DioException` with a response (Dio's `badResponse`: it throws for a 4xx and a 5xx) is a
  ///   [TransportStatusError] with the status, the lower-case headers and the body as bytes;
  /// * anything else is returned unchanged.
  static Object toTransport(Object error) {
    if (error is! DioException) return error;
    final cause = error.error;
    if (cause is TransportFailure) return cause;
    if (error.type == DioExceptionType.cancel) {
      return TransportAborted(error, error.requestOptions.uri);
    }
    final response = error.response;
    if (response != null) {
      return TransportStatusError(
        statusCode: response.statusCode ?? 0,
        headers: <String, String>{
          for (final entry in response.headers.map.entries)
            entry.key.toLowerCase(): entry.value.join(', '),
        },
        body: _bytes(response.data),
        reasonPhrase: response.statusMessage,
      );
    }
    return error;
  }

  static Uint8List _bytes(Object? data) {
    if (data == null) return Uint8List(0);
    if (data is Uint8List) return data;
    if (data is List<int>) return Uint8List.fromList(data);
    if (data is String) return Uint8List.fromList(utf8.encode(data));
    if (data is ResponseBody) return Uint8List(0);
    try {
      return Uint8List.fromList(utf8.encode(jsonEncode(data)));
    } on Object {
      return Uint8List.fromList(utf8.encode('$data'));
    }
  }
}
