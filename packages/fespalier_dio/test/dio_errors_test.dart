// DioErrors.toTransport: what the generated client throws (a DioException) as the transport's
// own errors, so a reader that knows no Dio type can classify it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

final _options = RequestOptions(path: 'https://api.example.com/orders');

DioException _dio(
  DioExceptionType type, {
  Object? error,
  Response<dynamic>? response,
}) => DioException(
  requestOptions: _options,
  type: type,
  error: error,
  response: response,
);

Response<dynamic> _response(
  int status,
  Object? data, {
  Map<String, List<String>> headers = const {},
}) => Response<dynamic>(
  requestOptions: _options,
  statusCode: status,
  statusMessage: 'status',
  data: data,
  headers: Headers.fromMap(headers),
);

void main() {
  group('DioErrors.toTransport', () {
    test('a DioException caused by a TransportFailure is that failure', () {
      for (final failure in <TransportFailure>[
        const TransportUnsent(),
        const TransportUntrusted(),
        const TransportTimedOut(),
        const TransportBroken(),
        const TransportPortal(),
        const TransportAborted(),
      ]) {
        final type = switch (failure) {
          TransportAborted() => DioExceptionType.cancel,
          TransportUnsent() => DioExceptionType.connectionError,
          TransportUntrusted() => DioExceptionType.badCertificate,
          TransportTimedOut() => DioExceptionType.receiveTimeout,
          TransportBroken() || TransportPortal() => DioExceptionType.unknown,
        };
        expect(
          DioErrors.toTransport(_dio(type, error: failure)),
          same(failure),
          reason: '$failure',
        );
      }
    });

    test('the cause wins over a response the exception also carries', () {
      const failure = TransportPortal();
      final error = _dio(
        DioExceptionType.badResponse,
        error: failure,
        response: _response(200, '<html></html>'),
      );
      expect(DioErrors.toTransport(error), same(failure));
    });

    test('a cancel is TransportAborted, with the cancelled request\'s url', () {
      final result = DioErrors.toTransport(_dio(DioExceptionType.cancel));
      expect(result, isA<TransportAborted>());
      expect((result as TransportAborted).uri, _options.uri);
    });

    test('a response is a TransportStatusError with lower-case headers', () {
      final result = DioErrors.toTransport(
        _dio(
          DioExceptionType.badResponse,
          response: _response(
            422,
            Uint8List.fromList(utf8.encode('{"error":"bad"}')),
            headers: {
              'Content-Type': ['application/json'],
              'Set-Cookie': ['a=1', 'b=2'],
            },
          ),
        ),
      );
      expect(result, isA<TransportStatusError>());
      final status = result as TransportStatusError;
      expect(status.statusCode, 422);
      expect(status.headers['content-type'], 'application/json');
      expect(status.headers['set-cookie'], 'a=1, b=2');
      expect(utf8.decode(status.body), '{"error":"bad"}');
    });

    test('a decoded body is encoded back to bytes', () {
      TransportStatusError of(Object? data) =>
          DioErrors.toTransport(
                _dio(
                  DioExceptionType.badResponse,
                  response: _response(500, data),
                ),
              )
              as TransportStatusError;
      expect(utf8.decode(of('plain').body), 'plain');
      expect(utf8.decode(of({'a': 1}).body), '{"a":1}');
      expect(of(<int>[1, 2, 3]).body, [1, 2, 3]);
      expect(of(null).body, isEmpty);
    });

    test('anything else is returned unchanged', () {
      final noResponse = _dio(DioExceptionType.connectionError);
      expect(DioErrors.toTransport(noResponse), same(noResponse));
      final other = StateError('x');
      expect(DioErrors.toTransport(other), same(other));
      const failure = TransportBroken();
      expect(DioErrors.toTransport(failure), same(failure));
    });
  });
}
