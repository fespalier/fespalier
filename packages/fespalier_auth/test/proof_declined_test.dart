// What the session gives an authenticator that steps up per request (since 0.25.0; a device
// session's `DeviceSigner` does): one memo per logical request, seen on every send, and the server's
// refusal back when the user declines the proof a replay needed (`ProofDeclined`). Also
// `Authorizer.unattended`, the zone form of `Authorizer.stepUpAttribute: false`.
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final api = Uri.parse('https://api.example.com');
final pay = Uri.parse('https://api.example.com/pay');

const stepUpHeader = 'Bearer error="insufficient_user_authentication"';

/// A user who declined a prompt.
final class Declined implements ProofDeclined {
  const Declined();
}

TransportResponse stepUp() => fakeResponse(
  401,
  headers: {'www-authenticate': stepUpHeader},
  body: '{"error":"insufficient_user_authentication"}',
);

void main() {
  late FakeAuthenticator authenticator;
  late ProviderContainer container;
  late FakeTransport server;
  late FakeAuthBackend backend;

  void setUpSession(List<TransportResponse> answers) {
    authenticator = FakeAuthenticator(
      // What a per-request step-up looks like: send the request again, once.
      verdict: (_, request, status, headers, _, retried) =>
          StepUpChallenge.fromResponse(status, headers) != null &&
              !retried &&
              Authorizer.attended(request)
          ? const Resend()
          : const Accept(),
    );
    backend = FakeAuthBackend(authenticator: authenticator);
    server = FakeTransport.script(answers);
    container = containerFor(
      signedInAs: ada,
      backend: backend,
      apiOrigins: [api],
      transport: server,
    );
  }

  HttpTransport transport() => container.read(authTransport);

  TransportRequest post() => TransportRequest(
    method: 'POST',
    uri: pay,
    body: utf8.encode('{"id":1}'),
    headers: const {'idempotency-key': 'k1'},
  );

  group('a ProofDeclined', () {
    test(
      'while authorizing a replay: the refusal that asked for it is the answer',
      () async {
        setUpSession([stepUp(), fakeResponse(200)]);
        authenticator.refuse = (request) =>
            request.memo!.get<bool>('replay') == true ? const Declined() : null;
        authenticator.verdict = (_, request, status, _, _, _) {
          if (status != 401) return const Accept();
          request.memo!.set('replay', true);
          return const Resend();
        };
        final response = await transport().send(post());
        expect(response.statusCode, 401);
        expect(jsonDecode(utf8.decode(await response.bytes())), {
          'error': 'insufficient_user_authentication',
        }, reason: 'the body is handed on whole');
        expect(server.requests, hasLength(1), reason: 'nothing more was sent');
        expect(container.read(authSession), isA<SignedIn>());
        expect(backend.stepUps, 0);
        expect(backend.renewals, 0);
      },
    );

    test(
      'on a first send fails the request, as any error of headers',
      () async {
        setUpSession([fakeResponse(200)]);
        authenticator.refuse = (_) => const Declined();
        await expectLater(transport().send(post()), throwsA(isA<Declined>()));
        expect(server.requests, isEmpty);
        expect(container.read(authSession), isA<SignedIn>());
      },
    );

    test('any other error while authorizing a replay propagates', () async {
      setUpSession([stepUp(), fakeResponse(200)]);
      var sends = 0;
      authenticator.refuse = (_) => ++sends == 2 ? StateError('no key') : null;
      await expectLater(transport().send(post()), throwsStateError);
    });
  });

  group('the memo', () {
    test(
      'is the same on every send of a request whose client keeps none, and is not sent below',
      () async {
        setUpSession([stepUp(), fakeResponse(200)]);
        expect((await transport().send(post())).statusCode, 200);
        final memos = [for (final r in authenticator.signed) r.memo];
        expect(memos, hasLength(2));
        expect(memos.first, isNotNull);
        expect(identical(memos.first, memos.last), isTrue);
        for (final sent in server.requests) {
          expect(
            sent.request.attributes.containsKey(TransportMemo.key),
            isFalse,
            reason: 'below the session, the attributes are the caller\'s',
          );
        }
      },
    );

    test('is the client\'s own when it keeps one', () async {
      setUpSession([fakeResponse(200)]);
      final memo = TransportMemo();
      await transport().send(
        post().copyWith(attributes: <String, Object?>{TransportMemo.key: memo}),
      );
      expect(authenticator.signed.single.memo, same(memo));
    });
  });

  group('Authorizer.unattended', () {
    test('a StepUp verdict inside it never asks the user', () async {
      setUpSession([stepUp(), fakeResponse(200)]);
      authenticator.verdict = null; // the default: a challenge is a StepUp
      final response = await Authorizer.unattended(
        () => transport().send(post()),
      );
      expect(response.statusCode, 401);
      expect(backend.stepUps, 0);
      expect(server.requests, hasLength(1));
    });

    test('an authenticator reads it through Authorizer.attended', () async {
      setUpSession([stepUp(), fakeResponse(200)]);
      final response = await Authorizer.unattended(
        () => transport().send(post()),
      );
      expect(response.statusCode, 401);
      expect(server.requests, hasLength(1));
      // Outside the zone, the same request steps up.
      setUpSession([stepUp(), fakeResponse(200)]);
      expect((await transport().send(post())).statusCode, 200);
    });

    test('returns what its body returns', () {
      expect(Authorizer.unattended(() => 42), 42);
      expect(
        Authorizer.attended(TransportRequest(method: 'GET', uri: api)),
        isTrue,
      );
      expect(
        Authorizer.unattended(
          () => Authorizer.attended(TransportRequest(method: 'GET', uri: api)),
        ),
        isFalse,
      );
      expect(
        Authorizer.attended(
          TransportRequest(
            method: 'GET',
            uri: api,
            attributes: const {Authorizer.stepUpAttribute: false},
          ),
        ),
        isFalse,
      );
    });
  });

  test('StepUpChallenge.fromResponse with schemes: null reads any scheme', () {
    const device = {
      'www-authenticate': 'Device error="insufficient_user_authentication"',
    };
    expect(StepUpChallenge.fromResponse(401, device), isNull);
    expect(
      StepUpChallenge.fromResponse(401, device, schemes: null),
      const StepUpChallenge(),
    );
    expect(
      StepUpChallenge.fromResponse(403, device, schemes: null),
      isNull,
      reason: 'a step-up refusal is a 401',
    );
  });
}
