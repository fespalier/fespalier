// The one classification everything else reads, and the field errors of a validation refusal.
import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/dio.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

CrateStackFailure envelope(
  int status, {
  String code = 'X',
  String message = 'm',
  bool retryAfter = false,
  Object? details,
}) => CrateStackFailure.fromEnvelope(
  status: status,
  code: code,
  message: message,
  retryAfter: retryAfter,
  details: details,
);

CrateStackFailure validation(String message, {Object? details}) =>
    envelope(422, code: 'VALIDATION_ERROR', message: message, details: details);

DioException dioError(
  int status, {
  Object? data,
  Map<String, List<String>> headers = const {},
  DioExceptionType type = DioExceptionType.badResponse,
}) {
  final options = RequestOptions(path: '/x');
  return DioException(
    requestOptions: options,
    type: type,
    response: Response<Object?>(
      requestOptions: options,
      statusCode: status,
      data: data,
      headers: Headers.fromMap(headers),
    ),
  );
}

void main() {
  group('the status and code table', () {
    test('401 is unauthenticated', () {
      expect(envelope(401), isA<CrateStackUnauthenticated>());
    });
    test('409 with Retry-After is in flight, without it a conflict', () {
      expect(envelope(409, retryAfter: true), isA<CrateStackInFlight>());
      expect(
        envelope(409, code: 'STALE'),
        isA<CrateStackConflict>().having((e) => e.code, 'code', 'STALE'),
      );
    });
    test('other 4xx are refusals with the wire code', () {
      for (final status in [400, 403, 404, 412, 422, 429]) {
        expect(
          envelope(status, code: 'C$status'),
          isA<CrateStackRefused>()
              .having((e) => e.status, 'status', status)
              .having((e) => e.code, 'code', 'C$status'),
        );
      }
    });
    test('5xx is unavailable, not offline', () {
      for (final status in [500, 502, 503]) {
        expect(envelope(status), isA<CrateStackUnavailable>());
      }
    });
  });

  group('responses without an envelope', () {
    CrateStackFailure? read(int status, {Object? body, String? type}) =>
        CrateStackFailure.fromResponse(
          status: status,
          body: body,
          contentType: type,
        );

    test('gateway statuses are offline: the call may have landed', () {
      for (final status in [502, 503, 504, 511]) {
        expect(read(status), isA<CrateStackOffline>(), reason: '$status');
      }
    });
    test('an HTML page is offline, even with a 200 (a captive portal)', () {
      expect(
        read(200, body: '<html>', type: 'text/html; charset=utf-8'),
        isA<CrateStackOffline>(),
      );
    });
    test('a bare 500 is not offline', () {
      expect(read(500), isA<CrateStackUnavailable>());
    });
    test('a success with no page is no failure', () {
      expect(read(200, body: {'a': 1}, type: 'application/json'), isNull);
    });
    test('an envelope wins over the gateway status', () {
      expect(
        read(503, body: {'code': 'UNAVAILABLE', 'message': 'busy'}),
        isA<CrateStackUnavailable>(),
      );
    });
    test('a bare 4xx is a refusal with an HTTP_ code', () {
      expect(
        read(404),
        isA<CrateStackRefused>().having((e) => e.code, 'code', 'HTTP_404'),
      );
      expect(read(401), isA<CrateStackUnauthenticated>());
    });
  });

  group('CrateStackErrors', () {
    test('a failure passes through as itself', () {
      const failure = CrateStackInFlight();
      expect(const CrateStackErrors([]).classify(failure), same(failure));
    });
    test('the first reader that knows wins; unknown is null', () {
      final errors = CrateStackErrors([
        (e) => e is FormatException ? const CrateStackCancelled() : null,
        (e) => e is FormatException ? const CrateStackInFlight() : null,
      ]);
      expect(
        errors.classify(const FormatException()),
        isA<CrateStackCancelled>(),
      );
      expect(errors.classify(StateError('x')), isNull);
    });
  });

  group('DioFailures', () {
    test('connection errors and timeouts are offline', () {
      for (final type in [
        DioExceptionType.connectionError,
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        final error = DioException(
          requestOptions: RequestOptions(),
          type: type,
        );
        expect(
          DioFailures.read(error),
          isA<CrateStackOffline>(),
          reason: '$type',
        );
      }
    });
    test('a cancel is cancelled', () {
      final error = DioException.requestCancelled(
        requestOptions: RequestOptions(),
        reason: 'x',
      );
      expect(DioFailures.read(error), isA<CrateStackCancelled>());
    });
    test('gateway pages are offline, a bare 500 is not', () {
      expect(DioFailures.read(dioError(502)), isA<CrateStackOffline>());
      expect(DioFailures.read(dioError(504)), isA<CrateStackOffline>());
      expect(
        DioFailures.read(
          dioError(
            200,
            data: '<html>',
            headers: {
              'content-type': ['text/html'],
            },
          ),
        ),
        isA<CrateStackOffline>(),
      );
      expect(DioFailures.read(dioError(500)), isA<CrateStackUnavailable>());
    });
    test(
      'an envelope is classified by status, and Retry-After makes 409 in flight',
      () {
        final body = {'code': 'IDEMPOTENCY_IN_FLIGHT', 'message': 'wait'};
        expect(
          DioFailures.read(
            dioError(
              409,
              data: body,
              headers: {
                'retry-after': ['1'],
              },
            ),
          ),
          isA<CrateStackInFlight>(),
        );
        expect(
          DioFailures.read(dioError(409, data: body)),
          isA<CrateStackConflict>(),
        );
        expect(
          DioFailures.read(
            dioError(403, data: {'code': 'FORBIDDEN', 'message': 'no'}),
          ),
          isA<CrateStackRefused>().having((e) => e.code, 'code', 'FORBIDDEN'),
        );
      },
    );
    test('anything else is not its to read', () {
      expect(DioFailures.read(StateError('x')), isNull);
      expect(
        DioFailures.read(DioException(requestOptions: RequestOptions())),
        isNull,
      );
    });
  });

  group('field errors', () {
    const errors = CrateStackErrors([]);

    test('a map of field to message maps field by field', () {
      final out = errors.fieldErrorsOf(
        validation(
          'invalid',
          details: {'email': 'is not a valid email address'},
        ),
      );
      expect(out!.fields, {'email': 'is not a valid email address'});
    });

    test('a list of {field|path, message} maps field by field', () {
      final out = errors.fieldErrorsOf(
        validation(
          'invalid',
          details: [
            {'field': 'email', 'message': 'bad'},
            {'path': 'name', 'message': 'short'},
          ],
        ),
      );
      expect(out!.fields, {'email': 'bad', 'name': 'short'});
    });

    test('the documented message names the field', () {
      final out = errors.fieldErrorsOf(
        validation("field 'email' is not a valid email address"),
      );
      expect(out!.fields.keys, ['email']);
      expect(out.fields['email'], contains('not a valid email address'));
    });

    test('details of a shape nobody documented fall back to the message', () {
      final out = errors.fieldErrorsOf(
        validation("field 'age' must be positive", details: {'weird': 1}),
      );
      expect(out!.fields.keys, ['age']);
    });

    test('otherwise the message is the form-level message', () {
      final out = errors.fieldErrorsOf(validation('something is wrong'));
      expect(out!.fields, isEmpty);
      expect(out.message, 'something is wrong');
    });

    test('fieldName maps the server key to the form field', () {
      final out = errors.fieldErrorsOf(
        validation('x', details: {'nick_name': 'taken'}),
        fieldName: (k) => k == 'nick_name' ? 'nickname' : k,
      );
      expect(out!.fields.keys, ['nickname']);
    });

    test('idempotency_key_conflict is never a field error', () {
      expect(
        errors.fieldErrorsOf(
          validation(
            'idempotency_key_conflict: the key was used with another body',
          ),
        ),
        isNull,
      );
    });

    test('anything but a 422 VALIDATION_ERROR is not a field error', () {
      expect(errors.fieldErrorsOf(envelope(422, code: 'OTHER')), isNull);
      expect(
        errors.fieldErrorsOf(envelope(400, code: 'VALIDATION_ERROR')),
        isNull,
      );
      expect(errors.fieldErrorsOf(const CrateStackOffline()), isNull);
      expect(errors.fieldErrorsOf(StateError('x')), isNull);
    });

    test(
      'withCrateStackFieldErrors throws FieldErrors for a validation refusal',
      () async {
        final ref = containerFor().read(refProvider);
        final future = Future<int>.error(
          validation('x', details: {'email': 'bad'}),
        ).withCrateStackFieldErrors(ref);
        await expectLater(
          future,
          throwsA(
            isA<FieldErrors>().having((e) => e.fields, 'fields', {
              'email': 'bad',
            }),
          ),
        );
      },
    );

    test('anything else is rethrown as the very same object', () async {
      final ref = containerFor().read(refProvider);
      final other = StateError('boom');
      await expectLater(
        Future<int>.error(other).withCrateStackFieldErrors(ref),
        throwsA(same(other)),
      );
      const offline = CrateStackOffline();
      await expectLater(
        Future<int>.error(offline).withCrateStackFieldErrors(ref),
        throwsA(same(offline)),
      );
      expect(await Future<int>.value(3).withCrateStackFieldErrors(ref), 3);
    });

    test('it reads with the readers of crateStackErrors', () async {
      final container = containerFor(
        extra: [
          crateStackErrors.overrideWithValue(
            CrateStackErrors([
              (e) => e is FormatException
                  ? const CrateStackRefused(
                      status: 422,
                      code: 'VALIDATION_ERROR',
                      message: "field 'a' is bad",
                    )
                  : null,
            ]),
          ),
        ],
      );
      await expectLater(
        Future<int>.error(
          const FormatException(),
        ).withCrateStackFieldErrors(container.read(refProvider)),
        throwsA(isA<FieldErrors>()),
      );
    });
  });
}
