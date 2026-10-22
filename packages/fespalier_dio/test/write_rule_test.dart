// WriteGuard (Dio) and WriteGuardTransport answer "is this a write?" from one rule, HttpWrites in
// fespalier_transport. This runs the same requests through both and the rule itself, so a copy of
// the rule in either one fails here.
import 'package:dio/dio.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const methods = [
    'GET',
    'get',
    'HEAD',
    'OPTIONS',
    'TRACE',
    'POST',
    'put',
    'PATCH',
    'DELETE',
    'PROPFIND',
  ];
  const headerSets = <Map<String, String>>[
    {},
    {'Content-Type': 'application/json'},
    {'Idempotency-Key': 'k'},
    {'idempotency-key': 'k'},
    {'Content-Type': 'application/json', 'IDEMPOTENCY-KEY': 'k'},
  ];

  for (final method in methods) {
    for (final headers in headerSets) {
      test('$method $headers: both guards agree with HttpWrites', () {
        final rule = HttpWrites.isWrite(method, headers.keys);
        final request = TransportRequest(
          method: method,
          uri: Uri.parse('https://example.com/x'),
          headers: headers,
        );
        final options = RequestOptions(
          path: '/x',
          method: method,
          headers: headers,
        );
        expect(WriteGuardTransport.isWrite(request), rule);
        expect(WriteGuard.isWrite(options), rule);
        // `extra[write]` declares a write; the Idempotency-Key still beats it.
        final declared = RequestOptions(
          path: '/x',
          method: method,
          headers: headers,
          extra: {WriteGuard.write: true},
        );
        expect(
          WriteGuard.isWrite(declared),
          HttpWrites.isWrite(method, headers.keys, declared: true),
        );
      });
    }
  }

  test('extra[idempotent] makes any request repeatable', () {
    for (final method in methods) {
      final options = RequestOptions(
        path: '/x',
        method: method,
        extra: {WriteGuard.write: true, WriteGuard.idempotent: true},
      );
      expect(WriteGuard.isWrite(options), isFalse, reason: method);
    }
  });
}
