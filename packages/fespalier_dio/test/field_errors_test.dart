// Server validation errors as FieldErrors: every shape of the table in docs/http.md, the renaming, the
// statuses, the 422 message-only rule, and the two withFieldErrors() (Dio and package:http).
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_dio/http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// `fieldErrorsOf(422, body)` as plain data: the fields, and the message.
({Map<String, String> fields, String? message})? decode(
  Object? body, {
  int status = 422,
  FieldErrorsDecoder decoder = FieldErrorsDecoders.standard,
  String Function(String key) fieldName = FieldNames.asIs,
}) {
  final errors = fieldErrorsOf(
    status,
    body,
    decoder: decoder,
    fieldName: fieldName,
  );
  return errors == null
      ? null
      : (fields: errors.fields, message: errors.message);
}

void main() {
  group('the shapes (docs/http.md, "Server validation errors on forms")', () {
    test(
      'RFC 9457 errors with pointers, in the fragment and the string form',
      () {
        final result = decode({
          'type': 'https://example.com/probs/validation',
          'title': 'Your request is not valid.',
          'errors': [
            {'detail': 'must be a positive integer', 'pointer': '#/age'},
            {
              'detail': "must be 'green', 'red' or 'blue'",
              'pointer': '/profile/color',
            },
          ],
        });
        expect(result?.fields, {
          'age': 'must be a positive integer',
          'profile.color': "must be 'green', 'red' or 'blue'",
        });
        // The generic title is not a message of the form while fields matched.
        expect(result?.message, isNull);
      },
    );

    test(
      'an RFC 9457 entry without a pointer is the message of the whole input',
      () {
        final result = decode({
          'errors': [
            {'detail': 'The two passwords differ'},
            {'detail': 'too short', 'pointer': '#/password'},
          ],
        });
        expect(result?.fields, {'password': 'too short'});
        expect(result?.message, 'The two passwords differ');
      },
    );

    test('RFC 7807 invalid-params', () {
      final result = decode({
        'type': 'https://example.net/validation-error',
        'title': 'Your request parameters didn\'t validate.',
        'invalid-params': [
          {'name': 'age', 'reason': 'must be a positive integer'},
          {'name': 'color', 'reason': "must be 'green', 'red' or 'blue'"},
        ],
      });
      expect(result?.fields, {
        'age': 'must be a positive integer',
        'color': "must be 'green', 'red' or 'blue'",
      });
    });

    test(
      'Spring: errors with field and defaultMessage (or message, or detail)',
      () {
        final result = decode({
          'timestamp': '2026-10-03T10:00:00.000+00:00',
          'status': 400,
          'error': 'Bad Request',
          'errors': [
            {
              'codes': ['Email.user.email'],
              'defaultMessage': 'must be a well-formed email address',
              'field': 'email',
              'rejectedValue': 'x',
            },
            {'field': 'name', 'message': 'must not be blank'},
            {'field': 'age', 'detail': 'must be positive'},
          ],
        }, status: 400);
        expect(result?.fields, {
          'email': 'must be a well-formed email address',
          'name': 'must not be blank',
          'age': 'must be positive',
        });
      },
    );

    test('ASP.NET Core: errors map, keys as the server cases them', () {
      final body = {
        'type': 'https://tools.ietf.org/html/rfc9110#section-15.5.1',
        'title': 'One or more validation errors occurred.',
        'status': 400,
        'errors': {
          'Nickname': ['The Nickname field is required.', 'Too short.'],
        },
      };
      expect(decode(body, status: 400)?.fields, {
        'Nickname': 'The Nickname field is required.',
      });
      expect(
        decode(body, status: 400, fieldName: FieldNames.camelCase)?.fields,
        {'nickname': 'The Nickname field is required.'},
      );
    });

    test(
      'ASP.NET Core: an empty or dollar key is the message, and "\$." is dropped',
      () {
        final result = decode({
          'errors': {
            '': ['The request is not valid.'],
            r'$.age': ['The JSON value could not be converted.'],
            r'$': ['ignored: the first one wins'],
          },
        }, status: 400);
        expect(result?.message, 'The request is not valid.');
        expect(result?.fields, {
          'age': 'The JSON value could not be converted.',
        });
      },
    );

    test('Laravel: the generic message is not used while fields matched', () {
      final result = decode({
        'message': 'The given data was invalid.',
        'errors': {
          'email': ['The email has already been taken.'],
        },
      });
      expect(result?.fields, {'email': 'The email has already been taken.'});
      expect(result?.message, isNull);
    });

    test('Rails: errors map without a message', () {
      final result = decode({
        'errors': {
          'email': ["can't be blank"],
        },
      });
      expect(result?.fields, {'email': "can't be blank"});
    });

    test(
      'JSON:API: source pointers, with data/attributes and data/relationships dropped',
      () {
        final result = decode({
          'errors': [
            {
              'status': '422',
              'source': {'pointer': '/data/attributes/firstName'},
              'title': 'Invalid Attribute',
              'detail': "can't be blank",
            },
            {
              'source': {'pointer': '/data/relationships/author'},
              'detail': 'must exist',
            },
            {'status': '422', 'detail': 'The record is locked'},
          ],
        });
        expect(result?.fields, {
          'firstName': "can't be blank",
          'author': 'must exist',
        });
        expect(result?.message, 'The record is locked');
      },
    );

    test(
      'JSON:API is not read as RFC 9457 by standard (a source says whose it is)',
      () {
        final body = {
          'errors': [
            {
              'source': {'pointer': '/data/attributes/name'},
              'detail': 'too short',
            },
          ],
        };
        expect(FieldErrorsDecoders.problemDetails(body), isNull);
        expect(FieldErrorsDecoders.standard(body)?.fields, {
          'name': 'too short',
        });
      },
    );

    test('FastAPI and Pydantic: loc without body/query/path/header/cookie', () {
      final result = decode({
        'detail': [
          {
            'loc': ['body', 'age'],
            'msg': 'Input should be greater than 0',
            'type': 'greater_than',
          },
          {
            'loc': ['body', 'profile', 'color'],
            'msg': 'Input should be red',
            'type': 'literal_error',
          },
          {
            'loc': ['body', 'items', 0, 'name'],
            'msg': 'Field required',
            'type': 'missing',
          },
          {
            'loc': ['query', 'q'],
            'msg': 'Field required',
            'type': 'missing',
          },
          {
            'loc': ['body'],
            'msg': 'Input should be a valid dictionary',
            'type': 'dict_type',
          },
        ],
      });
      expect(result?.fields, {
        'age': 'Input should be greater than 0',
        'profile.color': 'Input should be red',
        'items.0.name': 'Field required',
        'q': 'Field required',
      });
      expect(result?.message, 'Input should be a valid dictionary');
    });

    test(
      'Django REST framework: a flat map, non_field_errors as the message',
      () {
        final result = decode({
          'nickname': ['This field may not be blank.', 'Another.'],
          'age': 'A plain string is a message too',
          'non_field_errors': ['The two fields do not match.'],
        }, status: 400);
        expect(result?.fields, {
          'nickname': 'This field may not be blank.',
          'age': 'A plain string is a message too',
        });
        expect(result?.message, 'The two fields do not match.');
      },
    );

    test(
      'the flat map refuses anything that has a problem or an envelope key',
      () {
        for (final body in <Map<String, Object?>>[
          {'detail': 'Not found.'},
          {'title': 'Bad', 'status': 400, 'nickname': 'x'},
          {
            'type': 'x',
            'nickname': ['y'],
          },
          {'message': 'Something went wrong'},
          {'error': 'Something went wrong'},
          {
            'nickname': ['ok'],
            'count': 3,
          }, // a number is not a message
          {'nickname': <String>[]},
          <String, Object?>{},
        ]) {
          expect(FieldErrorsDecoders.flatMap(body), isNull, reason: '$body');
        }
        // A field that is called message is a list, as DRF writes it.
        expect(
          FieldErrorsDecoders.flatMap({
            'message': ['Required.'],
          })?.fields,
          {'message': 'Required.'},
        );
      },
    );

    test('a decoder returns null for a body that is not its shape', () {
      for (final body in <Object?>[
        null,
        'text',
        42,
        <Object?>[],
        {'errors': 3},
      ]) {
        expect(FieldErrorsDecoders.standard(body), isNull, reason: '$body');
      }
    });
  });

  group('fieldErrorsOf', () {
    test('only the statuses it is given: 400 and 422 by default', () {
      final body = {
        'errors': {
          'a': ['x'],
        },
      };
      expect(fieldErrorsOf(400, body), isNotNull);
      expect(fieldErrorsOf(422, body), isNotNull);
      for (final status in [null, 200, 401, 404, 409, 500]) {
        expect(fieldErrorsOf(status, body), isNull, reason: '$status');
      }
      expect(fieldErrorsOf(409, body, statuses: {409}), isNotNull);
      expect(fieldErrorsOf(400, body, statuses: {409}), isNull);
    });

    test(
      'a 422 that says what is wrong without naming fields is a message',
      () {
        expect(
          decode({
            'type': 'about:blank',
            'title': 'Unprocessable Entity',
            'status': 422,
            'detail': 'That nickname is taken',
          })?.message,
          'That nickname is taken',
        );
        expect(
          decode({'message': 'The order is closed'})?.message,
          'The order is closed',
        );
        // detail wins over message.
        expect(decode({'detail': 'd', 'message': 'm'})?.message, 'd');
        expect(decode({'detail': 'That nickname is taken'})?.fields, isEmpty);
      },
    );

    test(
      'a 400 without field errors is never converted: it is a bug of the client',
      () {
        expect(decode({'detail': 'Malformed JSON'}, status: 400), isNull);
        expect(decode({'message': 'Malformed JSON'}, status: 400), isNull);
      },
    );

    test('a 422 whose detail is not a string, or empty, is not a message', () {
      expect(decode({'detail': <Object?>[]}), isNull);
      expect(decode({'detail': '  '}), isNull);
      expect(decode({'title': 'Unprocessable'}), isNull);
    });

    test(
      'a String, bytes, or a map is read; anything else, or bad JSON, is not',
      () {
        const json = '{"errors":{"nick":["taken"]}}';
        expect(decode(json)?.fields, {'nick': 'taken'});
        expect(decode(utf8.encode(json))?.fields, {'nick': 'taken'});
        expect(decode(jsonDecode(json))?.fields, {'nick': 'taken'});
        expect(decode('{"errors":'), isNull);
        expect(decode(<int>[0xff, 0xfe]), isNull);
        expect(decode('[1, 2]'), isNull);
        expect(decode(''), isNull);
      },
    );

    test('bytes are UTF-8, as JSON is', () {
      final bytes = utf8.encode('{"errors":{"nick":["Déjà pris ✓"]}}');
      expect(decode(bytes)?.fields, {'nick': 'Déjà pris ✓'});
    });

    test(
      'keys are renamed with fieldName, and the first of two that collide wins',
      () {
        final result = decode({
          'errors': {
            'nick_name': ['taken'],
            'nickname': ['too long'],
            'other_key': ['x'],
          },
        }, fieldName: (key) => const {'nick_name': 'nickname'}[key] ?? key);
        expect(result?.fields, {'nickname': 'taken', 'other_key': 'x'});
      },
    );

    test('a decoder of your own gets the body as a map and is asked first', () {
      Object? seen;
      final result = decode(
        '{"fail":{"nick":"bad"}}',
        decoder: (body) {
          seen = body;
          final fail =
              (body! as Map<String, Object?>)['fail']! as Map<String, Object?>;
          return FieldErrors({
            for (final e in fail.entries) e.key: '${e.value}',
          });
        },
      );
      expect(seen, isA<Map<String, Object?>>());
      expect(result?.fields, {'nick': 'bad'});
    });

    test(
      'a decoder that finds nothing leaves the 422 message rule to apply',
      () {
        final result = decode({'detail': 'nope'}, decoder: (_) => null);
        expect(result?.message, 'nope');
        expect(
          decode({'a': 'b'}, decoder: (_) => const FieldErrors({})),
          isNull,
        );
      },
    );

    test('an empty FieldErrors is never returned', () {
      expect(decode({'errors': <String, Object?>{}}), isNull);
      expect(decode({'errors': <Object?>[]}), isNull);
      expect(
        decode({
          'errors': {'a': <Object?>[]},
        }),
        isNull,
      );
      expect(
        decode({
          'errors': {'a': ''},
        }),
        isNull,
      );
    });
  });

  group('JSON pointers', () {
    test(
      '~1 and ~0 are unescaped, and percent escapes of the fragment form too',
      () {
        final result = decode({
          'errors': [
            {'detail': 'a', 'pointer': '#/a~1b/c~0d'},
            {'detail': 'b', 'pointer': '/x~01'},
            {'detail': 'c', 'pointer': '#/a%20b'},
            {'detail': 'd', 'pointer': '/items/2/name'},
          ],
        });
        expect(result?.fields, {
          'a/b.c~d': 'a',
          'x~1': 'b',
          'a b': 'c',
          'items.2.name': 'd',
        });
      },
    );

    test('the root of the document is the message', () {
      for (final pointer in ['', '#', '/', '#/']) {
        final result = decode({
          'errors': [
            {'detail': 'whole', 'pointer': pointer},
          ],
        });
        expect(result?.message, 'whole', reason: pointer);
        expect(result?.fields, isEmpty);
      }
    });
  });

  group('FieldNames', () {
    test('asIs keeps the key', () {
      expect(FieldNames.asIs('first_name'), 'first_name');
    });

    test('camelCase handles snake, Pascal, kebab and SCREAMING', () {
      const cases = {
        'first_name': 'firstName',
        'FirstName': 'firstName',
        'first-name': 'firstName',
        'FIRST_NAME': 'firstName',
        'firstName': 'firstName',
        'Nickname': 'nickname',
        'nickname': 'nickname',
        'user_ID': 'userId',
        'ID': 'id',
        'HTTPServer': 'httpServer',
        'a': 'a',
        '': '',
        'address.street_name': 'address.streetName',
        'Items.0.Name': 'items.0.name',
        '_private': 'private',
      };
      for (final entry in cases.entries) {
        expect(FieldNames.camelCase(entry.key), entry.value, reason: entry.key);
      }
    });

    test('names that differ by more than case are not guessed', () {
      expect(FieldNames.camelCase('nick_name'), 'nickName'); // not `nickname`
    });
  });

  group('Dio: withFieldErrors()', () {
    DioException failure(int status, Object? data) {
      final options = RequestOptions(path: '/me', method: 'PUT');
      return DioException.badResponse(
        statusCode: status,
        requestOptions: options,
        response: Response<Object?>(
          requestOptions: options,
          statusCode: status,
          data: data,
        ),
      );
    }

    Future<Response<Object?>> failing(int status, Object? data) =>
        Future<Response<Object?>>.error(failure(status, data));

    test(
      'a validation answer is thrown as the FieldErrors it describes',
      () async {
        final future =
            failing(422, {
              'errors': {
                'nick_name': ['That nickname is taken'],
              },
            }).withFieldErrors(
              fieldName: (key) => const {'nick_name': 'nickname'}[key] ?? key,
            );
        await expectLater(
          future,
          throwsA(
            isA<FieldErrors>().having((e) => e.fields, 'fields', {
              'nickname': 'That nickname is taken',
            }),
          ),
        );
      },
    );

    test('a success completes with the same response', () async {
      final response = Response<Object?>(
        requestOptions: RequestOptions(path: '/me'),
        statusCode: 200,
        data: 'ok',
      );
      expect(
        identical(
          await Future<Response<Object?>>.value(response).withFieldErrors(),
          response,
        ),
        isTrue,
      );
    });

    test(
      'an error that is not a validation answer is rethrown: the very same object',
      () async {
        for (final error in [
          failure(500, {'message': 'oops'}),
          failure(422, 'not json'),
          failure(422, {'unrelated': 1}),
          failure(400, {'detail': 'Malformed JSON'}),
          DioException(
            requestOptions: RequestOptions(path: '/me'),
            type: DioExceptionType.connectionError,
          ),
        ]) {
          Object? thrown;
          try {
            await Future<void>.error(error).withFieldErrors();
          } on Object catch (e) {
            thrown = e;
          }
          expect(identical(thrown, error), isTrue, reason: '$error');
        }
      },
    );

    test(
      'an error that is not a DioException passes through untouched',
      () async {
        final error = StateError('boom');
        Object? thrown;
        try {
          await Future<void>.error(error).withFieldErrors();
        } on Object catch (e) {
          thrown = e;
        }
        expect(identical(thrown, error), isTrue);
      },
    );

    test(
      'bytes and String bodies, as a response type other than json gives',
      () async {
        const json = '{"errors":{"age":["Too young"]}}';
        for (final data in <Object>[json, utf8.encode(json)]) {
          await expectLater(
            failing(422, data).withFieldErrors(),
            throwsA(
              isA<FieldErrors>().having((e) => e.fields, 'fields', {
                'age': 'Too young',
              }),
            ),
          );
        }
      },
    );

    test('the statuses and the decoder are the caller\'s', () async {
      await expectLater(
        failing(409, {
          'errors': {
            'a': ['x'],
          },
        }).withFieldErrors(statuses: {409}),
        throwsA(isA<FieldErrors>()),
      );
      await expectLater(
        failing(422, {
          'errors': {
            'a': ['x'],
          },
        }).withFieldErrors(statuses: {400}),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        failing(422, {
          'x': 1,
        }).withFieldErrors(decoder: (_) => const FieldErrors({'a': 'mine'})),
        throwsA(
          isA<FieldErrors>().having((e) => e.fields, 'fields', {'a': 'mine'}),
        ),
      );
    });
  });

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
