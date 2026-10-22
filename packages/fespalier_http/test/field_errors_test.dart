// withFieldErrors() on a package:http future: the decoders it uses are fespalier's own
// (packages/fespalier/test/problem_test.dart).
import 'dart:convert';

import 'package:fespalier/fespalier.dart' show FieldErrors;
import 'package:fespalier_http/fespalier_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('package:http: withFieldErrors()', () {
    Future<http.Response> answer(
      int status,
      Object body, {
      Map<String, String>? headers,
    }) => Future.value(
      body is List<int>
          ? http.Response.bytes(body, status, headers: headers ?? const {})
          : http.Response(body as String, status, headers: headers ?? const {}),
    );

    test(
      'a validation answer is thrown as the FieldErrors it describes',
      () async {
        await expectLater(
          answer(
            422,
            '{"errors":[{"detail":"That nickname is taken","pointer":"#/nickname"}]}',
          ).withFieldErrors(),
          throwsA(
            isA<FieldErrors>().having((e) => e.fields, 'fields', {
              'nickname': 'That nickname is taken',
            }),
          ),
        );
      },
    );

    test('anything else is the response, as it is', () async {
      for (final response in [
        http.Response('{"ok":true}', 200),
        http.Response('{"errors":{"a":["x"]}}', 500),
        http.Response('not json', 422),
        http.Response('', 422),
        http.Response('{"detail":"Malformed"}', 400),
      ]) {
        expect(
          identical(await Future.value(response).withFieldErrors(), response),
          isTrue,
        );
      }
    });

    test('the body is UTF-8 even when the headers do not say so', () async {
      // package:http decodes `body` as Latin-1 without a charset; JSON is UTF-8.
      final bytes = utf8.encode('{"errors":{"nick":["Déjà pris"]}}');
      await expectLater(
        answer(422, bytes).withFieldErrors(),
        throwsA(
          isA<FieldErrors>().having(
            (e) => e.fields['nick'],
            'nick',
            'Déjà pris',
          ),
        ),
      );
    });

    test('a request that failed to send is not touched', () async {
      final error = http.ClientException('offline');
      Object? thrown;
      try {
        await Future<http.Response>.error(error).withFieldErrors();
      } on Object catch (e) {
        thrown = e;
      }
      expect(identical(thrown, error), isTrue);
    });
  });
}
