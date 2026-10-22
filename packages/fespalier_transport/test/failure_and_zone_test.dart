// The failures a transport throws, the status error a client can carry, and the abort trigger
// that travels in a zone.
import 'dart:async';
import 'dart:typed_data';

import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TransportFailure', () {
    test('every kind keeps the cause and the uri and names no server', () {
      final uri = Uri.parse('https://secret.example.com/orders?id=1');
      final cause = StateError('boom');
      final failures = <TransportFailure>[
        TransportAborted(cause, uri),
        TransportUnsent(cause, uri),
        TransportTimedOut(cause, uri),
        TransportBroken(cause, uri),
        TransportPortal(cause, uri),
        TransportUntrusted(cause, uri),
      ];
      for (final failure in failures) {
        expect(failure.cause, same(cause));
        expect(failure.uri, uri);
        expect('$failure', isNot(contains('secret.example.com')));
        expect('$failure', startsWith('${failure.runtimeType}: '));
      }
    });

    test('a portal is a failure of its own, not an unsent request', () {
      const TransportFailure portal = TransportPortal();
      expect(portal, isA<TransportPortal>());
      expect(portal, isNot(isA<TransportUnsent>()));
      expect(portal.summary, contains('other than the API'));
      // A switch over the sealed class names every kind, the portal included.
      final name = switch (portal) {
        TransportAborted() => 'aborted',
        TransportUnsent() => 'unsent',
        TransportTimedOut() => 'timed out',
        TransportBroken() => 'broken',
        TransportPortal() => 'portal',
        TransportUntrusted() => 'untrusted',
      };
      expect(name, 'portal');
    });

    test('a refused certificate is neither unsent nor broken', () {
      const TransportFailure untrusted = TransportUntrusted();
      expect(untrusted, isNot(isA<TransportUnsent>()));
      expect(untrusted, isNot(isA<TransportBroken>()));
      expect(untrusted.summary, contains('certificate'));
      expect('$untrusted', startsWith('TransportUntrusted: '));
    });
  });

  group('TransportStatusError', () {
    test('carries the status, the lower-cased headers and the body bytes', () {
      final error = TransportStatusError(
        statusCode: 422,
        headers: const {'content-type': 'application/json'},
        body: Uint8List.fromList([123, 125]),
        reasonPhrase: 'Unprocessable Entity',
      );
      expect(error.statusCode, 422);
      expect(error.headers['content-type'], 'application/json');
      expect(error.body, [123, 125]);
      expect(error.reasonPhrase, 'Unprocessable Entity');
      expect(error, isA<Exception>());
      expect(error, isNot(isA<TransportFailure>()));
    });

    test('toString shows the status and never the body', () {
      final error = TransportStatusError(
        statusCode: 500,
        headers: const {},
        body: Uint8List.fromList('ada@example.com'.codeUnits),
      );
      expect('$error', 'TransportStatusError: HTTP 500');
    });
  });

  group('TransportZone', () {
    test('there is no trigger outside a zone that sets one', () {
      expect(TransportZone.current(), isNull);
    });

    test('run sets the trigger for the body and what it awaits', () async {
      final trigger = Completer<void>();
      final seen = <Future<void>?>[];
      await TransportZone.run(trigger.future, () async {
        seen.add(TransportZone.current());
        await Future<void>.delayed(Duration.zero);
        seen.add(TransportZone.current());
        await Future<void>(() => seen.add(TransportZone.current()));
      });
      expect(seen, hasLength(3));
      for (final s in seen) {
        expect(s, same(trigger.future));
      }
      expect(TransportZone.current(), isNull);
    });

    test('run returns what the body returns, synchronously', () {
      final trigger = Completer<void>();
      final result = TransportZone.run(trigger.future, () => 42);
      expect(result, 42);
    });

    test('a nested run replaces the trigger for its own body only', () {
      final outer = Completer<void>();
      final inner = Completer<void>();
      TransportZone.run(outer.future, () {
        expect(TransportZone.current(), same(outer.future));
        TransportZone.run(inner.future, () {
          expect(TransportZone.current(), same(inner.future));
        });
        expect(TransportZone.current(), same(outer.future));
      });
    });

    test('the key is a plain zone value other code can read', () {
      final trigger = Completer<void>();
      TransportZone.run(trigger.future, () {
        expect(Zone.current[TransportZone.abortTrigger], same(trigger.future));
      });
    });

    test('merge completes with whichever trigger completes first', () async {
      final a = Completer<void>();
      final b = Completer<void>();
      final merged = TransportZone.merge(a.future, b.future)!;
      var done = false;
      unawaited(merged.then<void>((_) => done = true));
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      b.complete();
      await merged;
      expect(done, isTrue);
    });

    test('merge of one or none is that one or null', () {
      final a = Completer<void>().future;
      expect(TransportZone.merge(a, null), same(a));
      expect(TransportZone.merge(null, a), same(a));
      expect(TransportZone.merge(null, null), isNull);
    });
  });
}
