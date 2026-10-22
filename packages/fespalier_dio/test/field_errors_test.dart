// withFieldErrors() on a Dio future.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
