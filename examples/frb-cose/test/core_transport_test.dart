import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frb_cose_example/src/core.dart';
import 'package:frb_cose_example/src/core_transport.dart';
import 'package:frb_cose_example/src/notes.dart';

import 'support/fakes.dart';

const _add = RpcCall(Ops.addNote, {'text': 'hi'});
const _list = RpcCall(Ops.listNotes, <String, Object?>{});

/// The answer table of [CoreTransport], row by row, over a fake core that answers what the test scripts.
void main() {
  late FakeNotesCore core;
  setUp(() => core = FakeNotesCore());
  CoreTransport transport() => CoreTransport(core);

  test(
    'a sealed 2xx is the result, and the call reaches the core with its arguments and key',
    () async {
      core.next.add(
        const CoreAnswer(status: 200, bodyJson: '{"id":1,"text":"hi"}'),
      );

      final result = await transport().send(_add, idempotencyKey: 'k#0');

      expect(result, {'id': 1, 'text': 'hi'});
      expect(core.calls.single, (
        op: 'addNote',
        argsJson: '{"text":"hi"}',
        idempotencyKey: 'k#0',
      ));
    },
  );

  test('a read sends no key, and its arguments are the wire input', () async {
    core.next.add(
      const CoreAnswer(
        status: 200,
        bodyJson: '{"notes":[{"id":1,"text":"a"}]}',
      ),
    );

    final result = await transport().send(_list);

    expect(notesFromWire(result), [const Note(id: 1, text: 'a')]);
    expect(core.calls.single, (
      op: 'listNotes',
      argsJson: '{}',
      idempotencyKey: '',
    ));
  });

  group('an unsigned answer, which the server did not seal', () {
    test('401 is unauthenticated: the same key is tried again later', () async {
      core.next.add(
        const CoreError(kind: CoreErrorKind.unsigned, status: 401, message: ''),
      );
      await expectLater(
        transport().send(_add, idempotencyKey: 'k#0'),
        throwsA(isA<CrateStackUnauthenticated>()),
      );
    });

    for (final status in [400, 413, 415, 426]) {
      test('$status is a refusal, with its status as the code', () async {
        core.next.add(
          CoreError(kind: CoreErrorKind.unsigned, status: status, message: ''),
        );
        await expectLater(
          transport().send(_add, idempotencyKey: 'k#0'),
          throwsA(
            isA<CrateStackRefused>()
                .having((e) => e.status, 'status', status)
                .having((e) => e.code, 'code', 'HTTP_$status'),
          ),
        );
      });
    }

    test('any other status is offline, under the same key', () async {
      core.next.add(
        const CoreError(kind: CoreErrorKind.unsigned, status: 503, message: ''),
      );
      await expectLater(
        transport().send(_add, idempotencyKey: 'k#0'),
        throwsA(isA<CrateStackOffline>()),
      );
    });
  });

  group('a sealed answer, which the server did seal', () {
    test('a sealed 401 is unauthenticated', () async {
      core.next.add(
        const CoreAnswer(
          status: 401,
          bodyJson: '{"code":"UNAUTHENTICATED","message":"no"}',
        ),
      );
      await expectLater(
        transport().send(_add, idempotencyKey: 'k#0'),
        throwsA(isA<CrateStackUnauthenticated>()),
      );
    });

    test('a sealed 422 is a refusal, read from its envelope', () async {
      core.next.add(
        const CoreAnswer(
          status: 422,
          bodyJson: '{"code":"invalid_argument","message":"text is too long"}',
        ),
      );
      await expectLater(
        transport().send(_add, idempotencyKey: 'k#0'),
        throwsA(
          isA<CrateStackRefused>()
              .having((e) => e.status, 'status', 422)
              .having((e) => e.code, 'code', 'invalid_argument')
              .having(
                (e) => e.toString(),
                'shown',
                'CrateStackRefused(422 invalid_argument)',
              ),
        ),
      );
    });

    test('a sealed 409 with a Retry-After hint is in flight', () async {
      core.next.add(
        const CoreAnswer(
          status: 409,
          retryAfter: 2,
          bodyJson: '{"code":"IN_FLIGHT","message":"busy"}',
        ),
      );
      await expectLater(
        transport().send(_add, idempotencyKey: 'k#0'),
        throwsA(isA<CrateStackInFlight>()),
      );
    });

    test(
      'a sealed 409 without one is a conflict the person resolves',
      () async {
        core.next.add(
          const CoreAnswer(
            status: 409,
            bodyJson: '{"code":"VERSION","message":"stale"}',
          ),
        );
        await expectLater(
          transport().send(_add, idempotencyKey: 'k#0'),
          throwsA(isA<CrateStackConflict>()),
        );
      },
    );

    test(
      'a sealed 5xx with an envelope is unavailable: the next key',
      () async {
        core.next.add(
          const CoreAnswer(
            status: 503,
            bodyJson: '{"code":"UNAVAILABLE","message":"down"}',
          ),
        );
        await expectLater(
          transport().send(_add, idempotencyKey: 'k#0'),
          throwsA(isA<CrateStackUnavailable>()),
        );
      },
    );

    test(
      'a sealed 5xx without an envelope is offline, never a new key',
      () async {
        core.next.add(const CoreAnswer(status: 500, bodyJson: '"oops"'));
        await expectLater(
          transport().send(_add, idempotencyKey: 'k#0'),
          throwsA(isA<CrateStackOffline>()),
        );
      },
    );
  });

  group('no answer, or none the server sent', () {
    for (final kind in [
      CoreErrorKind.transport,
      CoreErrorKind.seal,
      CoreErrorKind.registration,
      CoreErrorKind.unverified,
    ]) {
      test('$kind is offline, under the same key', () async {
        core.next.add(CoreError(kind: kind, message: ''));
        await expectLater(
          transport().send(_add, idempotencyKey: 'k#0'),
          throwsA(
            isA<CrateStackOffline>().having((e) => e.cause, 'cause', kind),
          ),
        );
      });
    }
  });

  test('the core refuses a call it cannot make: an ArgumentError', () async {
    core.next.add(const CoreError(kind: CoreErrorKind.badInput, message: ''));
    await expectLater(transport().send(_add), throwsA(isA<ArgumentError>()));
  });

  test(
    'an op the core does not have is refused before the core is asked',
    () async {
      await expectLater(
        transport().send(const RpcCall('noSuchOp', <String, Object?>{})),
        throwsA(isA<ArgumentError>()),
      );
      expect(core.calls, isEmpty);
    },
  );

  test('a REST call is not this transport\'s', () async {
    await expectLater(
      transport().send(const RestCall('GET', '/notes')),
      throwsA(isA<UnsupportedError>()),
    );
    expect(core.calls, isEmpty);
  });
}
