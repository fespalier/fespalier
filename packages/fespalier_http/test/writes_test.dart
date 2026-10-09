// HttpWrites is the one rule for "is this request a write?": WriteGuard (fespalier_dio) and
// WriteGuardClient both call it, so this table is the rule and fespalier_dio's parity test checks
// that both clients agree with it.
import 'package:fespalier_http/fespalier_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('HttpWrites.isWrite', () {
    // method, header names, declared, is a write.
    final table = <(String, List<String>, bool, bool)>[
      ('GET', [], false, false),
      ('get', [], false, false),
      ('HEAD', [], false, false),
      ('OPTIONS', [], false, false),
      ('TRACE', [], false, false),
      ('POST', [], false, true),
      ('post', [], false, true),
      ('PUT', [], false, true),
      ('PATCH', [], false, true),
      ('DELETE', [], false, true),
      ('PROPFIND', [], false, true),
      // An Idempotency-Key makes a write repeatable, in any case.
      ('POST', ['Idempotency-Key'], false, false),
      ('POST', ['idempotency-key'], false, false),
      ('PUT', ['IDEMPOTENCY-KEY'], false, false),
      ('POST', ['Content-Type', 'Idempotency-Key'], false, false),
      ('POST', ['Content-Type'], false, true),
      // A declared write is one whatever its method.
      ('GET', [], true, true),
      ('HEAD', [], true, true),
      ('POST', [], true, true),
      // The key beats the declaration, as it always did.
      ('GET', ['Idempotency-Key'], true, false),
      ('POST', ['Idempotency-Key'], true, false),
    ];

    for (final (method, headers, declared, expected) in table) {
      test(
        '$method $headers declared=$declared is ${expected ? '' : 'not '}a write',
        () {
          expect(
            HttpWrites.isWrite(method, headers, declared: declared),
            expected,
          );
        },
      );
    }

    test('the constants are the ones the rule uses', () {
      expect(HttpWrites.safeMethods, {'GET', 'HEAD', 'OPTIONS', 'TRACE'});
      expect(HttpWrites.idempotencyKey, 'Idempotency-Key');
    });

    test('WriteGuardClient.isWrite is the rule, on a request', () {
      for (final (method, headers, declared, expected) in table) {
        if (declared) continue; // an http request cannot declare a write
        final request = http.Request(method, Uri.parse('https://example.com/x'))
          ..headers.addAll({for (final h in headers) h: '1'});
        expect(
          WriteGuardClient.isWrite(request),
          expected,
          reason: '$method $headers',
        );
      }
    });
  });
}
