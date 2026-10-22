// What is specific to tokens, end to end, on the real core: AuthSessionNotifier, the Authorizer and
// SessionTransport over an OidcBackend whose provider is a FakeTransport. Renewal with rotation,
// a 401 that renews once, a DPoP nonce, a restore that reads a stored token session, a sign-out
// that revokes, and the telemetry a renewal tells. The generic behaviour of the core on a fake
// backend is fespalier_auth's to test.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_oidc/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_provider.dart';
import 'support.dart';

final apiBase = Uri.parse('https://api.example.com');
final orders = Uri.parse('https://api.example.com/orders');

/// The API: it accepts the token whose `jti` is [good] (the newest the provider issued by
/// default) and answers 401 to every other.
final class Api {
  Api(this.provider);

  final Server provider;

  /// The `jti` of the one access token it takes; null: the newest the provider issued.
  String? good;

  /// How many of the first requests it answers 401 to, whatever the token.
  int refuseFirst = 0;

  /// Headers on every answer (a DPoP nonce).
  Map<String, String> extra = {};

  late final FakeTransport transport = FakeTransport((request, body) {
    final answered = transport.requests.length;
    final auth = request.headers['Authorization'];
    final token = auth?.split(' ').last;
    final jti = token == null ? null : unverifiedJwtClaims(token)?['jti'];
    final ok = answered > refuseFirst && jti == (good ?? 'a${provider.tokens}');
    return fakeResponse(
      ok ? 200 : 401,
      body: ok ? 'orders' : 'no',
      headers: extra,
    );
  });

  List<SentRequest> get seen => transport.requests;

  /// The `Authorization` header of each request, in order.
  List<String?> get authorizations => [
    for (final r in seen) r.header('authorization'),
  ];
}

/// A signed-in app: the real notifier over an [OidcBackend] and a fake provider and API.
final class Rig {
  Rig._({required this.proof, required this.dpop, Duration? renewAhead}) {
    provider.extra = dpop ? {'token_type': 'DPoP'} : {};
    oidc = OidcBackend(
      issuer: issuer,
      clientId: clientId,
      redirectUri: redirectUri,
      openBrowser: browser(provider),
      endpoints: endpoints,
      transport: provider.transport,
      proof: proof,
      renewAhead: renewAhead ?? const Duration(seconds: 30),
      random: Random(1),
    );
    store = SpyStore(storeLog);
    container = ProviderContainer(
      overrides: [
        authConfig.overrideWithValue(
          AuthConfig(
            backend: oidc,
            transport: provider.transport,
            store: store,
            apiOrigins: [apiBase],
          ),
        ),
        authInitialState.overrideWithValue(const SignedOut()),
      ],
    );
    addTearDown(container.dispose);
    notifier = container.read(authSession.notifier);
    api = Api(provider);
    transport = SessionTransport(api.transport, container.read(authorizer));
  }

  final FakeProof? proof;
  final bool dpop;
  final Server provider = Server();
  final List<String> storeLog = [];
  late final Api api;
  late final OidcBackend oidc;
  late final SpyStore store;
  late final ProviderContainer container;
  late final AuthSessionNotifier notifier;

  /// The transport that carries the session to the API.
  late final SessionTransport transport;

  Future<AuthSession> signIn() => notifier.signIn(const BrowserSignIn());

  AuthSession get session => notifier.session!;

  TokenCredential get tokens => session.credential as TokenCredential;

  String get access => tokens.accessToken;

  /// The refresh-token grants the provider has seen.
  int get renewals => provider.posts
      .where((p) => p.bodyFields['grant_type'] == 'refresh_token')
      .length;

  Future<TransportResponse> get(Uri uri) =>
      transport.send(TransportRequest(method: 'GET', uri: uri));
}

const lifetime = Duration(seconds: 300);

/// Runs [body] on a test clock with a rig that is signed in (unless [signedIn] is false).
void scenario(
  String name,
  Future<void> Function(Rig rig, TestTime time) body, {
  FakeProof? proof,
  bool dpop = false,
  bool signedIn = true,
  Duration? renewAhead,
}) {
  test(name, () {
    final time = TestTime();
    return time.run(() async {
      final rig = Rig._(proof: proof, dpop: dpop, renewAhead: renewAhead);
      if (signedIn) await rig.signIn();
      await body(rig, time);
    });
  });
}

void main() {
  group('renewal', () {
    scenario('a good access token is returned synchronously: not a Future', (
      rig,
      _,
    ) async {
      final credential = rig.notifier.credential();
      expect(credential, isA<TokenCredential>());
      expect(credential, isNot(isA<Future<Object?>>()));
      expect((credential as TokenCredential).refreshToken, 'refresh-1');
      expect(rig.renewals, 0);
    });

    scenario('inside renewAhead the token already counts as expired', (
      rig,
      time,
    ) async {
      time.elapse(lifetime - const Duration(seconds: 31));
      expect(rig.notifier.credential(), isA<TokenCredential>());
      time.elapse(const Duration(seconds: 2));
      final renewing = rig.notifier.credential();
      expect(renewing, isA<Future<SessionCredential>>());
      await renewing;
      expect(rig.renewals, 1);
    });

    scenario(
      'renewAhead is the backend\'s: two minutes ahead renews at 2:59 early',
      (rig, time) async {
        time.elapse(lifetime - const Duration(seconds: 121));
        expect(rig.notifier.credential(), isA<TokenCredential>());
        time.elapse(const Duration(seconds: 2));
        expect(rig.notifier.credential(), isA<Future<SessionCredential>>());
        await rig.notifier.credential();
        expect(rig.renewals, 1);
      },
      renewAhead: const Duration(minutes: 2),
    );

    scenario('three concurrent calls on an expired token share one renewal', (
      rig,
      time,
    ) async {
      final before = rig.access;
      time.elapse(const Duration(minutes: 6));
      rig.provider.gate = Completer<void>();
      final a = rig.notifier.credential();
      final b = rig.notifier.credential();
      final c = rig.notifier.credential();
      expect([a, b, c], everyElement(isA<Future<SessionCredential>>()));
      await pumpEventQueue();
      expect(rig.renewals, 1);
      expect(rig.access, before, reason: 'the old session while it is out');
      rig.provider.gate!.complete();
      final results = await Future.wait([
        a as Future<SessionCredential>,
        b as Future<SessionCredential>,
        c as Future<SessionCredential>,
      ]);
      expect(rig.renewals, 1);
      expect(results.map((t) => (t as TokenCredential).accessToken).toSet(), {
        rig.access,
      });
      expect(rig.access, isNot(before));
      expect(rig.notifier.credential(), isA<TokenCredential>());
    });

    scenario('a renewal does not publish a new SignedOut or flicker the guards', (
      rig,
      time,
    ) async {
      final signedIn = <bool>[];
      final users = <AuthUser?>[];
      final states = <SessionState>[];
      rig.container.listen(isSignedIn, (_, next) => signedIn.add(next));
      rig.container.listen(authUser, (_, next) => users.add(next));
      rig.container.listen(authSession, (_, next) => states.add(next));
      time.elapse(const Duration(minutes: 6));
      await rig.notifier.credential();
      expect(states, hasLength(1));
      expect(states.single, isA<SignedIn>());
      // The new ID token has another iat, and the access token another jti, and the user is the
      // same: nobody watching isSignedIn or authUser hears of a token swap.
      expect(signedIn, isEmpty);
      expect(users, isEmpty);
    });

    scenario('the rotated refresh token is stored before the state changes', (
      rig,
      time,
    ) async {
      String? storedWhenStateChanged;
      rig.container.listen(authSession, (_, next) {
        storedWhenStateChanged = rig.store.value;
      });
      rig.storeLog.clear();
      time.elapse(const Duration(minutes: 6));
      await rig.notifier.credential();
      expect(rig.storeLog, ['write']);
      expect(storedWhenStateChanged, isNotNull);
      expect(storedWhenStateChanged, contains('refresh-2'));
      expect(storedWhenStateChanged, isNot(contains('refresh-1')));
      final saved = AuthSession.fromJson(
        jsonDecode(rig.store.value!) as Map<String, Object?>,
        rig.oidc.readCredential,
      );
      expect(saved, rig.session);
      expect(rig.tokens.refreshToken, 'refresh-2');
    });

    scenario('the refresh token sent is the newest: rotation across renewals', (
      rig,
      time,
    ) async {
      for (var i = 0; i < 3; i++) {
        time.elapse(const Duration(minutes: 6));
        await rig.notifier.credential();
      }
      expect(
        [
          for (final p in rig.provider.posts)
            if (p.bodyFields['grant_type'] == 'refresh_token')
              p.bodyFields['refresh_token'],
        ],
        ['refresh-1', 'refresh-2', 'refresh-3'],
        reason: 'each renewal presents the token the last one returned',
      );
    });

    scenario(
      'rejected: an access token someone already replaced is not renewed again',
      (rig, time) async {
        final old = rig.tokens;
        time.elapse(const Duration(minutes: 6));
        await rig.notifier.credential();
        expect(rig.renewals, 1);
        // A request that carried the old token gets its 401 now.
        final again = rig.notifier.credential(rejected: old);
        expect(again, isA<TokenCredential>(), reason: 'no second renewal');
        expect((again as TokenCredential).accessToken, rig.access);
        expect(rig.renewals, 1, reason: 'a rotated token would be refused');
      },
    );

    scenario(
      'rejected: the token in use is renewed even though it looks good',
      (rig, _) async {
        final old = rig.tokens;
        final result = rig.notifier.credential(rejected: old);
        expect(result, isA<Future<SessionCredential>>());
        expect(
          (await result as TokenCredential).accessToken,
          isNot(old.accessToken),
        );
        expect(rig.renewals, 1);
      },
    );

    scenario('two 401s to the same token renew once', (rig, _) async {
      final old = rig.tokens;
      rig.provider.gate = Completer<void>();
      final a = rig.notifier.credential(rejected: old);
      final b = rig.notifier.credential(rejected: old);
      await pumpEventQueue();
      rig.provider.gate!.complete();
      await Future.wait([a as Future<Object?>, b as Future<Object?>]);
      expect(rig.renewals, 1);
    });

    scenario('forceRenew renews a good token', (rig, _) async {
      final old = rig.access;
      final result = rig.notifier.credential(forceRenew: true);
      expect(result, isA<Future<SessionCredential>>());
      expect((await result as TokenCredential).accessToken, isNot(old));
    });

    scenario('a renewal the provider refuses signs out with reason expired', (
      rig,
      time,
    ) async {
      rig.provider
        ..status = 400
        ..body = {
          'error': 'invalid_grant',
          'error_description': 'Token is not active',
        };
      time.elapse(const Duration(minutes: 6));
      rig.provider.gate = Completer<void>();
      final a = rig.notifier.credential() as Future<SessionCredential>;
      final b = rig.notifier.credential() as Future<SessionCredential>;
      final failures = [
        expectLater(
          a,
          throwsA(
            isA<AuthRejected>().having(
              (e) => e.error,
              'error',
              'invalid_grant',
            ),
          ),
        ),
        expectLater(b, throwsA(isA<AuthRejected>())),
      ];
      rig.provider.gate!.complete();
      await Future.wait(failures);
      expect(
        rig.container.read(authSession),
        const SignedOut(reason: SignOutReason.expired),
      );
      expect(rig.store.value, isNull, reason: 'the store is cleared');
      expect(rig.renewals, 1);
      expect(() => rig.notifier.credential(), throwsA(isA<NotSignedIn>()));
    });

    scenario(
      'a refused renewal forgets the key: the proof is reset',
      (rig, time) async {
        rig.provider
          ..status = 400
          ..body = {'error': 'invalid_grant'};
        time.elapse(const Duration(minutes: 6));
        await expectLater(
          rig.notifier.credential() as Future<SessionCredential>,
          throwsA(isA<AuthRejected>()),
        );
        await pumpEventQueue();
        expect(rig.proof!.resets, 1);
      },
      proof: FakeProof(),
      dpop: true,
    );

    scenario('a 503 keeps the session, and the next call asks again', (
      rig,
      time,
    ) async {
      final before = rig.access;
      rig.provider
        ..status = 503
        ..body = 'down';
      time.elapse(const Duration(minutes: 6));
      rig.provider.gate = Completer<void>();
      final a = rig.notifier.credential() as Future<SessionCredential>;
      final b = rig.notifier.credential() as Future<SessionCredential>;
      final failures = [
        expectLater(a, throwsA(isA<AuthUnavailable>())),
        expectLater(b, throwsA(isA<AuthUnavailable>())),
      ];
      rig.provider.gate!.complete();
      await Future.wait(failures);
      expect(rig.container.read(authSession), isA<SignedIn>());
      expect(rig.access, before);
      expect(rig.renewals, 1);

      rig.provider
        ..status = 200
        ..body = null
        ..gate = null;
      final next = await rig.notifier.credential() as TokenCredential;
      expect(next.accessToken, isNot(before));
      expect(next.refreshToken, 'refresh-2');
      expect(rig.renewals, 2);
    });

    scenario('an offline provider is an AuthUnavailable that names no host', (
      rig,
      time,
    ) async {
      rig.provider.answer = (_) =>
          throw const TransportUnsent('Connection refused');
      time.elapse(const Duration(minutes: 6));
      try {
        await (rig.notifier.credential() as Future<SessionCredential>);
        fail('expected a failure');
      } on AuthUnavailable catch (e) {
        expect(e.cause, isA<TransportUnsent>());
        expect('$e', isNot(contains('sso.example.com')));
      }
      expect(rig.container.read(authSession), isA<SignedIn>());
      expect(rig.store.value, isNotNull);
    });

    scenario(
      'signing out during a renewal: the waiters get NotSignedIn, and nothing is stored',
      (rig, time) async {
        time.elapse(const Duration(minutes: 6));
        rig.provider.gate = Completer<void>();
        rig.storeLog.clear();
        final waiting = rig.notifier.credential() as Future<SessionCredential>;
        final failure = expectLater(waiting, throwsA(isA<NotSignedIn>()));
        final out = rig.notifier.signOut();
        rig.provider.gate!.complete();
        await failure;
        await out;
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.user),
        );
        expect(
          rig.store.value,
          isNull,
          reason: 'the late tokens were not stored',
        );
        expect(rig.storeLog.where((e) => e == 'write'), isEmpty);
      },
    );

    test('an access token with no expires_in never expires by itself', () {
      final time = TestTime();
      return time.run(() async {
        final rig = Rig._(proof: null, dpop: false);
        rig.provider.answer = (_) =>
            rig.provider.tokenResponse()..remove('expires_in');
        await rig.signIn();
        expect(rig.tokens.expiresAt, isNull);
        time.elapse(const Duration(days: 30));
        expect(rig.notifier.credential(), isA<TokenCredential>());
        expect(rig.renewals, 0);
      });
    });

    test('with no refresh token the session ends with the access token', () {
      final time = TestTime();
      return time.run(() async {
        final rig = Rig._(proof: null, dpop: false);
        rig.provider.answer = (_) => rig.provider.tokenResponse()
          ..remove('refresh_token')
          ..remove('refresh_expires_in');
        await rig.signIn();
        expect(rig.tokens.renewable, isFalse);
        time.elapse(const Duration(minutes: 6));
        await expectLater(
          rig.notifier.credential() as Future<SessionCredential>,
          throwsA(isA<AuthRejected>()),
        );
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.expired),
        );
        expect(rig.renewals, 0, reason: 'nothing to present to the provider');
      });
    });
  });

  group('requests through SessionTransport', () {
    scenario('a request to the API carries the access token as a Bearer', (
      rig,
      _,
    ) async {
      final response = await rig.get(orders);
      expect(response.statusCode, 200);
      expect(rig.api.authorizations, ['Bearer ${rig.access}']);
    });

    scenario('an expired token is renewed before the request is sent', (
      rig,
      time,
    ) async {
      time.elapse(const Duration(minutes: 6));
      final response = await rig.get(orders);
      expect(response.statusCode, 200);
      expect(rig.api.authorizations, [
        'Bearer ${rig.access}',
      ], reason: 'one send, with the new token: no 401 round trip');
      expect(rig.renewals, 1);
    });

    scenario('a 401 renews once with the rejected token and sends it again', (
      rig,
      _,
    ) async {
      final first = rig.access;
      rig.api.good = 'a2';
      final response = await rig.get(orders);
      expect(response.statusCode, 200);
      expect(await response.bytes(), utf8.encode('orders'));
      expect(rig.renewals, 1);
      expect(rig.api.authorizations, ['Bearer $first', 'Bearer ${rig.access}']);
      expect(rig.access, isNot(first));
      expect(
        rig.provider.posts.last.bodyFields['refresh_token'],
        'refresh-1',
        reason:
            'the renewal presented the refresh token of the rejected session',
      );
      expect(rig.tokens.refreshToken, 'refresh-2');
      expect(rig.store.value, contains('refresh-2'));
    });

    scenario('the second send is marked as a replay, the first is not', (
      rig,
      _,
    ) async {
      rig.api.good = 'a2';
      await rig.get(orders);
      expect(
        [
          for (final r in rig.api.seen)
            r.request.attributes[transportReplayKey] == true,
        ],
        [false, true],
      );
    });

    scenario('a body is sent again, whole, with its headers', (rig, _) async {
      rig.api.good = 'a2';
      final body = Uint8List.fromList(utf8.encode('{"item":1}'));
      final response = await rig.transport.send(
        TransportRequest(
          method: 'POST',
          uri: orders,
          headers: const {'content-type': 'application/json'},
          body: body,
        ),
      );
      expect(response.statusCode, 200);
      expect(rig.api.seen, hasLength(2));
      for (final sent in rig.api.seen) {
        expect(sent.method, 'POST');
        expect(sent.text, '{"item":1}');
        expect(sent.header('content-type'), 'application/json');
      }
    });

    scenario('two requests that get a 401 together share one renewal', (
      rig,
      _,
    ) async {
      rig.api.good = 'a2';
      rig.provider.gate = Completer<void>();
      final a = rig.get(orders);
      final b = rig.get(Uri.parse('https://api.example.com/orders/1'));
      await pumpEventQueue();
      expect(rig.renewals, 1);
      rig.provider.gate!.complete();
      final responses = await Future.wait([a, b]);
      expect(responses.map((r) => r.statusCode), [200, 200]);
      expect(rig.renewals, 1);
      expect(rig.api.seen, hasLength(4));
    });

    scenario('a second 401 is returned as it is: no loop', (rig, _) async {
      rig.api.good = 'never';
      final response = await rig.get(orders);
      expect(response.statusCode, 401);
      expect(rig.api.seen, hasLength(2));
      expect(rig.renewals, 1);
    });

    scenario(
      'a 401 when the provider refuses the renewal: the 401 is returned and the user is signed out',
      (rig, _) async {
        rig.api.good = 'a2';
        rig.provider
          ..status = 400
          ..body = {'error': 'invalid_grant'};
        final response = await rig.get(orders);
        expect(response.statusCode, 401);
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.expired),
        );
        expect(rig.api.seen, hasLength(1));
        expect(rig.store.value, isNull);
      },
    );

    scenario(
      'a 401 when the renewal cannot run: AuthUnavailable, and the user stays signed in',
      (rig, _) async {
        rig.api.good = 'a2';
        rig.provider
          ..status = 503
          ..body = 'down';
        await expectLater(rig.get(orders), throwsA(isA<AuthUnavailable>()));
        expect(rig.container.read(authSession), isA<SignedIn>());
        expect(rig.api.seen, hasLength(1));
      },
    );

    scenario(
      'an expired token that cannot be renewed: AuthRejected / AuthUnavailable, no request is sent',
      (rig, time) async {
        time.elapse(const Duration(minutes: 6));
        rig.provider.answer = (_) =>
            throw const TransportUnsent('Connection refused');
        await expectLater(rig.get(orders), throwsA(isA<AuthUnavailable>()));
        rig.provider
          ..answer = null
          ..status = 400
          ..body = {'error': 'invalid_grant'};
        await expectLater(rig.get(orders), throwsA(isA<AuthRejected>()));
        expect(rig.api.seen, isEmpty);
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.expired),
        );
      },
    );

    scenario(
      'signed out: the request goes with no header, and nothing is renewed',
      (rig, _) async {
        final response = await rig.get(orders);
        expect(response.statusCode, 401);
        expect(rig.api.authorizations, [null]);
        expect(rig.api.seen, hasLength(1));
        expect(rig.provider.requests, isEmpty);
      },
      signedIn: false,
    );

    scenario(
      'the token endpoint\'s own origin is not an API origin: it gets no session',
      (rig, _) async {
        final inner = FakeTransport((_, _) => fakeResponse(200));
        final transport = SessionTransport(
          inner,
          rig.container.read(authorizer),
        );
        await transport.send(
          TransportRequest(method: 'GET', uri: endpoints.token),
        );
        expect(inner.requests.single.header('authorization'), isNull);
      },
    );
  });

  group('DPoP through SessionTransport', () {
    scenario(
      'a bound token goes with the DPoP scheme and a proof for the request',
      (rig, _) async {
        final response = await rig.get(
          Uri.parse('https://api.example.com/orders?page=2#top'),
        );
        expect(response.statusCode, 200);
        final sent = rig.api.seen.single;
        expect(sent.header('authorization'), 'DPoP ${rig.access}');
        expect(
          sent.header('dpop'),
          'fake-proof-2 GET https://api.example.com/orders ath',
          reason: 'proof 1 was the token endpoint\'s, with no ath',
        );
        expect(rig.tokens.jkt, 'fake-thumbprint');
      },
      proof: FakeProof(),
      dpop: true,
    );

    scenario(
      'a nonce challenge is answered once, with a new proof and no renewal',
      (rig, _) async {
        rig.proof!.challengeNext = true;
        rig.api.refuseFirst = 1;
        final response = await rig.get(orders);
        expect(response.statusCode, 200);
        expect(rig.api.seen, hasLength(2));
        expect(
          rig.api.seen.first.header('dpop'),
          'fake-proof-2 GET https://api.example.com/orders ath',
        );
        expect(
          rig.api.seen.last.header('dpop'),
          'fake-proof-3 GET https://api.example.com/orders ath nonce=nonce-1',
        );
        expect(rig.renewals, 0);
        expect(
          [
            for (final r in rig.api.seen)
              r.request.attributes[transportReplayKey] == true,
          ],
          [false, true],
        );
      },
      proof: FakeProof(),
      dpop: true,
    );

    scenario(
      'a request is sent at most three times: a challenge, a renewal, then it stands',
      (rig, _) async {
        rig.proof!.challengeNext = true;
        rig.api.good = 'never';
        final response = await rig.get(orders);
        expect(response.statusCode, 401);
        expect(rig.api.seen, hasLength(3));
        expect(rig.renewals, 1);
        // Each send has a proof of its own, and the renewed token's carries its own access token.
        expect(
          rig.proof!.proofs.where((p) => p.contains(' ath')),
          hasLength(3),
        );
        expect(rig.api.seen.last.header('authorization'), 'DPoP ${rig.access}');
        expect(
          rig.api.seen.first.header('authorization'),
          isNot(rig.api.seen.last.header('authorization')),
        );
      },
      proof: FakeProof(),
      dpop: true,
    );

    scenario(
      'a nonce sent on a success is remembered for the next request',
      (rig, _) async {
        rig.api.extra = {'dpop-nonce': 'abc'};
        await rig.get(orders);
        await rig.get(orders);
        expect(rig.api.seen.last.header('dpop'), endsWith('nonce=abc'));
      },
      proof: FakeProof(),
      dpop: true,
    );

    scenario(
      'a renewal carries a proof of the same key, and the new token is bound to it',
      (rig, _) async {
        rig.api.good = 'a2';
        await rig.get(orders);
        final renewal = rig.provider.posts.last;
        expect(renewal.bodyFields['grant_type'], 'refresh_token');
        expect(
          renewal.header('dpop'),
          startsWith('fake-proof-3 POST https://sso.example.com/'),
          reason: 'after the exchange (1) and the first API send (2)',
        );
        expect(rig.tokens.jkt, 'fake-thumbprint');
        expect(rig.api.seen.last.header('authorization'), 'DPoP ${rig.access}');
      },
      proof: FakeProof(),
      dpop: true,
    );

    scenario(
      'a DPoP token and a backend with no proof is a StateError, and nothing is sent',
      (rig, _) async {
        expect(rig.tokens.isDpop, isTrue);
        expect(rig.tokens.jkt, isNull);
        await expectLater(
          rig.get(orders),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('DPoP-bound'),
            ),
          ),
        );
        expect(rig.api.seen, isEmpty);
      },
      dpop: true,
    );

    scenario('a bearer token on a backend with a proof gets no DPoP header', (
      rig,
      _,
    ) async {
      // Keycloak's refresh-token-only binding: the access token is a plain bearer token.
      final before = rig.proof!.proofs.length;
      await rig.get(orders);
      expect(
        rig.api.seen.single.header('authorization'),
        'Bearer ${rig.access}',
      );
      expect(rig.api.seen.single.lowerHeaders.containsKey('dpop'), isFalse);
      expect(rig.proof!.proofs, hasLength(before));
    }, proof: FakeProof());
  });

  group('a retrier and DPoP', () {
    // A retry under SessionTransport re-sends the proof it was given: the same jti, which a server
    // refuses (Keycloak: "DPoP proof has already been used"). A retry over it asks for a new proof.
    test('under the session the retry re-sends the same proof', () {
      final time = TestTime();
      return time.run(() async {
        final proof = FakeProof();
        final rig = Rig._(proof: proof, dpop: true);
        await rig.signIn();
        final flaky = _Flaky(rig.api.transport);
        final transport = SessionTransport(
          _RetryOnce(flaky),
          rig.container.read(authorizer),
        );
        await transport.send(TransportRequest(method: 'GET', uri: orders));
        expect(flaky.calls, 2);
        expect(
          flaky.sent.map((r) => r.headers['DPoP']).toSet(),
          hasLength(1),
          reason: 'the same proof twice',
        );
        expect(proof.proofs.where((p) => p.contains(' ath')), hasLength(1));
      });
    });

    test('over the session every attempt has a proof of its own', () {
      final time = TestTime();
      return time.run(() async {
        final proof = FakeProof();
        final rig = Rig._(proof: proof, dpop: true);
        await rig.signIn();
        final flaky = _Flaky(rig.api.transport);
        final transport = _RetryOnce(
          SessionTransport(flaky, rig.container.read(authorizer)),
        );
        await transport.send(TransportRequest(method: 'GET', uri: orders));
        expect(flaky.calls, 2);
        expect(
          flaky.sent.map((r) => r.headers['DPoP']).toSet(),
          hasLength(2),
          reason: 'a fresh proof for each',
        );
        expect(proof.proofs.where((p) => p.contains(' ath')), hasLength(2));
      });
    });
  });

  group('the Authorizer as the HttpCredentials of a transfer', () {
    /// What a transfer of your own does with an [HttpCredentials]: ask before each send, ask after
    /// each response, at most three sends.
    Future<TransportResponse> transfer(
      HttpCredentials credentials,
      HttpTransport net,
      Uri url,
    ) async {
      HttpAuthorization? previous;
      final request = TransportRequest(method: 'GET', uri: url);
      for (var send = 1; ; send++) {
        final attempt = await credentials.authorize(
          request,
          previous: previous,
        );
        final response = await net.send(request.authorized(attempt));
        if (send == 3 || !await credentials.retry(attempt, response)) {
          return response;
        }
        previous = attempt;
      }
    }

    scenario(
      'a 401 drives one shared renewal and a second send with the new token',
      (rig, _) async {
        rig.api.good = 'a2';
        final response = await transfer(
          rig.container.read(authorizer),
          rig.api.transport,
          orders,
        );
        expect(response.statusCode, 200);
        expect(rig.renewals, 1);
        expect(rig.api.authorizations, [
          isNot('Bearer ${rig.access}'),
          'Bearer ${rig.access}',
        ]);
      },
    );

    scenario(
      'a proof nonce challenge is answered once, with no renewal',
      (rig, _) async {
        rig.proof!.challengeNext = true;
        rig.api.refuseFirst = 1;
        final response = await transfer(
          rig.container.read(authorizer),
          rig.api.transport,
          orders,
        );
        expect(response.statusCode, 200);
        expect(rig.renewals, 0);
        expect(rig.api.seen, hasLength(2));
        expect(rig.api.seen.last.header('dpop'), endsWith('nonce=nonce-1'));
      },
      proof: FakeProof(),
      dpop: true,
    );

    scenario(
      'the attempt carries the access token, the DPoP scheme and a proof',
      (rig, _) async {
        final credentials = rig.container.read(authorizer);
        final attempt = await credentials.authorize(
          TransportRequest(method: 'GET', uri: orders),
        );
        expect(attempt, isA<AuthAttempt>());
        expect(attempt.headers['Authorization'], 'DPoP ${rig.access}');
        expect(attempt.headers['DPoP'], contains(' GET '));
        expect(attempt.isReplay, isFalse);
        expect(attempt.credential, rig.tokens);
      },
      proof: FakeProof(),
      dpop: true,
    );
  });

  group('restore', () {
    String stored(AuthSession session) => jsonEncode(session.toJson());

    AuthSession session({
      String backend = 'oidc',
      String? jkt,
      DateTime? refreshExpiresAt,
      bool refreshToken = true,
      DateTime? expiresAt,
    }) => AuthSession(
      backend: backend,
      credential: TokenCredential(
        accessToken: 'fake-access-0',
        tokenType: jkt == null ? 'Bearer' : 'DPoP',
        refreshToken: refreshToken ? 'fake-refresh-0' : null,
        expiresAt: expiresAt,
        refreshExpiresAt: refreshExpiresAt,
        jkt: jkt,
      ),
      user: ada,
    );

    final provider = Server();
    OidcBackend backendOf([ProofOfPossession? proof]) => OidcBackend(
      issuer: issuer,
      clientId: clientId,
      redirectUri: redirectUri,
      openBrowser: browser(provider),
      endpoints: endpoints,
      transport: provider.transport,
      proof: proof,
    );

    SessionState stateOf(List<Override> overrides) {
      final container = ProviderContainer(overrides: overrides);
      addTearDown(container.dispose);
      return container.read(authSession);
    }

    late RecordingTelemetry rec;
    setUp(() {
      provider.requests.clear();
      rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
    });
    tearDown(() => FespalierTelemetry.install(null));

    test('a stored token session restores synchronously, signed in', () {
      final store = MemoryTokenStore(stored(session()));
      final result = restoreAuth(
        AuthConfig(
          backend: backendOf(),
          transport: provider.transport,
          store: store,
        ),
      );
      expect(result, isA<List<Override>>());
      expect(result, isNot(isA<Future<Object?>>()));
      final state = stateOf(result as List<Override>);
      expect(state, isA<SignedIn>());
      expect(state.user, ada);
      expect(
        (state as SignedIn).session.credential,
        isA<TokenCredential>().having(
          (t) => t.refreshToken,
          'refreshToken',
          'fake-refresh-0',
        ),
      );
      expect(rec.log, [
        '#1 start auth restore backend=oidc scheme=bearer',
        '#1 end auth ok',
      ]);
      expect(provider.requests, isEmpty, reason: 'restore never calls out');
    });

    test('a refresh token that has expired signs out with reason expired', () {
      final time = TestTime();
      final store = MemoryTokenStore(
        stored(
          session(
            refreshExpiresAt: time.now.subtract(const Duration(seconds: 1)),
          ),
        ),
      );
      final result = time.run(
        () => restoreAuth(
          AuthConfig(
            backend: backendOf(),
            transport: provider.transport,
            store: store,
          ),
        ),
      );
      expect(
        stateOf(result as List<Override>),
        const SignedOut(reason: SignOutReason.expired),
      );
      expect(store.value, isNull);
      expect(rec.log.last, '#1 end auth expired');
    });

    test('a refresh token that is still good keeps the session, offline too', () {
      final time = TestTime();
      final store = MemoryTokenStore(
        stored(
          session(
            refreshExpiresAt: time.now.add(const Duration(minutes: 1)),
            // The access token has expired: it is renewed by the first request, not at start-up.
            expiresAt: time.now.subtract(const Duration(minutes: 1)),
          ),
        ),
      );
      final result = time.run(
        () => restoreAuth(
          AuthConfig(
            backend: backendOf(),
            transport: provider.transport,
            store: store,
          ),
        ),
      );
      expect(stateOf(result as List<Override>), isA<SignedIn>());
      expect(provider.requests, isEmpty, reason: 'restore never renews');
    });

    test('an expired access token with nothing to renew it is expired', () {
      final time = TestTime();
      final store = MemoryTokenStore(
        stored(
          session(
            refreshToken: false,
            expiresAt: time.now.subtract(const Duration(seconds: 1)),
          ),
        ),
      );
      final result = time.run(
        () => restoreAuth(
          AuthConfig(
            backend: backendOf(),
            transport: provider.transport,
            store: store,
          ),
        ),
      );
      expect(
        stateOf(result as List<Override>),
        const SignedOut(reason: SignOutReason.expired),
      );
      expect(store.value, isNull);
    });

    test('a session bound to a key, and no proof: the key is lost', () {
      final store = MemoryTokenStore(stored(session(jkt: 'thumb')));
      final result = restoreAuth(
        AuthConfig(
          backend: backendOf(),
          transport: provider.transport,
          store: store,
        ),
      );
      expect(
        result,
        isNot(isA<Future<Object?>>()),
        reason: 'no proof to ask: the answer is known at once',
      );
      expect(
        stateOf(result as List<Override>),
        const SignedOut(reason: SignOutReason.keyLost),
      );
      expect(store.value, isNull);
    });

    test(
      'a session bound to a key, restored with another one: the key is lost',
      () async {
        final proof = FakeProof(thumbprintValue: 'another-device');
        final store = MemoryTokenStore(stored(session(jkt: 'this-device')));
        final result = restoreAuth(
          AuthConfig(
            backend: backendOf(proof),
            transport: provider.transport,
            store: store,
          ),
        );
        expect(
          result,
          isA<Future<List<Override>>>(),
          reason: 'the thumbprint is asked',
        );
        expect(
          stateOf(await result),
          const SignedOut(reason: SignOutReason.keyLost),
        );
        expect(store.value, isNull);
        expect(rec.log.first, '#1 start auth restore backend=oidc scheme=dpop');
        expect(rec.log.last, '#1 end auth expired async');
      },
    );

    test('a key that matches keeps the session', () async {
      final proof = FakeProof(thumbprintValue: 'this-device');
      final store = MemoryTokenStore(stored(session(jkt: 'this-device')));
      final result = restoreAuth(
        AuthConfig(
          backend: backendOf(proof),
          transport: provider.transport,
          store: store,
        ),
      );
      expect(result, isA<Future<List<Override>>>());
      expect(stateOf(await result), isA<SignedIn>());
      expect(store.value, isNotNull);
      expect(rec.log.last, '#1 end auth ok async');
    });

    test(
      'a session that is not bound to a key restores synchronously, proof or not',
      () {
        final store = MemoryTokenStore(stored(session()));
        final result = restoreAuth(
          AuthConfig(
            backend: backendOf(FakeProof()),
            transport: provider.transport,
            store: store,
          ),
        );
        expect(result, isNot(isA<Future<Object?>>()));
        expect(stateOf(result as List<Override>), isA<SignedIn>());
      },
    );

    test(
      'a session stored before 0.21.0 ("v": 1, "tokens") signs in again, reported once',
      () {
        final errors = <FlutterErrorDetails>[];
        final old = FlutterError.onError;
        FlutterError.onError = errors.add;
        addTearDown(() => FlutterError.onError = old);
        final v1 = jsonEncode({
          'v': 1,
          'backend': 'oidc',
          'tokens': {'accessToken': 'a', 'refreshToken': 'r'},
          'user': ada.toJson(),
          'binding': null,
        });
        final store = MemoryTokenStore(v1);
        final result = restoreAuth(
          AuthConfig(
            backend: backendOf(),
            transport: provider.transport,
            store: store,
          ),
        );
        expect(stateOf(result as List<Override>), const SignedOut());
        expect(store.value, isNull);
        expect(errors.single.exception, isA<FormatException>());
      },
    );

    test(
      'a signed-in session restores as the very session that was stored',
      () {
        final time = TestTime();
        return time.run(() async {
          final rig = Rig._(proof: FakeProof(), dpop: true);
          final signedIn = await rig.signIn();
          final restored = await restoreAuth(
            AuthConfig(
              backend: backendOf(FakeProof()),
              transport: provider.transport,
              store: MemoryTokenStore(rig.store.value),
            ),
          );
          expect(stateOf(restored), SignedIn(signedIn));
        });
      },
    );
  });

  group('sign-in and sign-out', () {
    scenario('signing in stores a session a restore reads back', (
      rig,
      _,
    ) async {
      expect(rig.container.read(authSession), isA<SignedIn>());
      expect(rig.storeLog, ['write']);
      expect(rig.session.backend, 'oidc');
      expect(rig.session.user.id, 'u-1');
      expect(rig.session.user.roles, {'admin', 'offline_access', 'buyer'});
      final saved = AuthSession.fromJson(
        jsonDecode(rig.store.value!) as Map<String, Object?>,
        rig.oidc.readCredential,
      );
      expect(saved, rig.session);
    });

    test('a closed browser is AuthCancelled, and nothing changes', () async {
      final provider = Server();
      final oidc = OidcBackend(
        issuer: issuer,
        clientId: clientId,
        redirectUri: redirectUri,
        openBrowser: (_, _) async => throw const AuthCancelled(),
        endpoints: endpoints,
        transport: provider.transport,
      );
      final store = MemoryTokenStore();
      final container = ProviderContainer(
        overrides: [
          authConfig.overrideWithValue(
            AuthConfig(
              backend: oidc,
              transport: provider.transport,
              store: store,
              apiOrigins: [apiBase],
            ),
          ),
          authInitialState.overrideWithValue(const SignedOut()),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(authSession.notifier).signIn(const BrowserSignIn()),
        throwsA(isA<AuthCancelled>()),
      );
      expect(container.read(authSession), const SignedOut());
      expect(provider.requests, isEmpty);
      expect(store.value, isNull);
    });

    scenario('a provider that refuses the code leaves the state unchanged', (
      rig,
      _,
    ) async {
      rig.provider
        ..status = 400
        ..body = {
          'error': 'invalid_grant',
          'error_description': 'Code not valid',
        };
      await expectLater(rig.signIn(), throwsA(isA<OidcException>()));
      expect(rig.container.read(authSession), const SignedOut());
      expect(rig.store.value, isNull);
    }, signedIn: false);

    scenario(
      'signing out is synchronous to SignedOut, then clears the store, revokes the refresh token and resets the proof',
      (rig, _) async {
        final refresh = rig.tokens.refreshToken;
        rig.store.value = 'kept';
        rig.storeLog.clear();
        rig.provider.requests.clear();
        final states = <SessionState>[];
        rig.container.listen(authSession, (_, next) => states.add(next));

        final done = rig.notifier.signOut();
        // Before the first await: guards that watch the session move in this frame.
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.user),
        );
        expect(states, [const SignedOut(reason: SignOutReason.user)]);
        expect(
          rig.provider.requests,
          isEmpty,
          reason: 'revocation comes after',
        );
        await done;
        expect(rig.storeLog, ['delete']);
        expect(rig.store.value, isNull);
        final revocation = rig.provider.posts.single;
        expect(revocation.url, endpoints.revocation);
        expect(revocation.bodyFields, {
          'token': refresh,
          'token_type_hint': 'refresh_token',
          'client_id': clientId,
        });
        expect(rig.proof!.resets, 1);
        expect(rig.proof!.nonce, isNull);
      },
      proof: FakeProof(),
      dpop: true,
    );

    scenario(
      'a revocation that fails is swallowed: the user is out anyway, and the proof is reset',
      (rig, _) async {
        rig.provider.answer = (_) => throw const TransportBroken();
        await rig.notifier.signOut();
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.user),
        );
        expect(rig.store.value, isNull);
        expect(rig.proof!.resets, 1);
      },
      proof: FakeProof(),
      dpop: true,
    );

    scenario('after a sign-out the user can sign in again', (rig, _) async {
      await rig.notifier.signOut();
      final again = await rig.signIn();
      expect(again.credential, isA<TokenCredential>());
      expect(rig.container.read(authSession), isA<SignedIn>());
      expect(
        (again.credential as TokenCredential).refreshToken,
        isNot('refresh-1'),
      );
    });
  });

  group('telemetry', () {
    late RecordingTelemetry rec;
    setUp(() {
      rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
    });
    tearDown(() => FespalierTelemetry.install(null));

    scenario('a renewal span carries the scheme: bearer', (rig, time) async {
      rec.log.clear();
      time.elapse(const Duration(minutes: 6));
      await rig.notifier.credential();
      expect(spans(rec), [
        'start auth renew backend=oidc trigger=expired scheme=bearer',
        'end auth ok async',
      ]);
    });

    scenario(
      'a renewal span carries the scheme: dpop',
      (rig, time) async {
        rec.log.clear();
        time.elapse(const Duration(minutes: 6));
        await rig.notifier.credential();
        expect(
          rec.log.first,
          endsWith('renew backend=oidc trigger=expired scheme=dpop'),
        );
        expect(rec.log.last, endsWith('end auth ok async'));
      },
      proof: FakeProof(),
      dpop: true,
    );

    scenario('a renewal says what asked for it', (rig, time) async {
      rec.log.clear();
      time.elapse(const Duration(minutes: 6));
      await rig.notifier.credential();
      await rig.notifier.credential(rejected: rig.tokens);
      await rig.notifier.credential(forceRenew: true);
      expect(
        [
          for (final line in rec.log)
            if (line.contains(' start auth '))
              line.replaceFirst(RegExp(r'^#\d+ '), ''),
        ],
        [
          'start auth renew backend=oidc trigger=expired scheme=bearer',
          'start auth renew backend=oidc trigger=unauthorized scheme=bearer',
          'start auth renew backend=oidc trigger=forced scheme=bearer',
        ],
      );
    });

    scenario('a shared renewal is one span, however many wait', (
      rig,
      time,
    ) async {
      rec.log.clear();
      time.elapse(const Duration(minutes: 6));
      await Future.wait([
        rig.notifier.credential() as Future<SessionCredential>,
        rig.notifier.credential() as Future<SessionCredential>,
        rig.notifier.credential() as Future<SessionCredential>,
      ]);
      expect(
        rec.log.where((l) => l.contains('start auth renew')),
        hasLength(1),
      );
    });

    scenario('a good token asks for nothing: no span', (rig, _) async {
      rec.log.clear();
      expect(rig.notifier.credential(), isA<TokenCredential>());
      expect(rec.log, isEmpty);
    });

    scenario(
      'sign-in and sign-out are told with the scheme',
      (rig, _) async {
        await rig.notifier.signOut();
        expect(rec.log, [
          '#1 start auth sign_in backend=oidc scheme=dpop',
          '#1 end auth ok async',
          '#2 start auth sign_out backend=oidc scheme=dpop',
          '#2 end auth ok async',
        ]);
      },
      proof: FakeProof(),
      dpop: true,
    );

    scenario('a refused renewal is rejected; one that cannot run is an error', (
      rig,
      time,
    ) async {
      time.elapse(const Duration(minutes: 6));
      rig.provider.answer = (_) =>
          throw const TransportUnsent('Connection refused');
      await expectLater(
        rig.notifier.credential() as Future<SessionCredential>,
        throwsA(isA<AuthUnavailable>()),
      );
      rig.provider
        ..answer = null
        ..status = 400
        ..body = {'error': 'invalid_grant'};
      await expectLater(
        rig.notifier.credential() as Future<SessionCredential>,
        throwsA(isA<AuthRejected>()),
      );
      final ends = rec.log.where((l) => l.contains(' end auth ')).toList();
      expect(ends, hasLength(3), reason: 'sign-in, then the two renewals');
      expect(ends[1], contains('end auth error async error=AuthUnavailable'));
      expect(ends[1], isNot(contains('sso.example.com')));
      expect(ends[2], endsWith('end auth rejected async'));
    });

    scenario(
      'nothing that identifies anybody is ever told: no token, id, e-mail, name, code or URL',
      (rig, time) async {
        time.elapse(const Duration(minutes: 6));
        await rig.notifier.credential();
        await rig.get(orders);
        await rig.notifier.signOut();
        final text = rec.log.join('\n');
        for (final secret in [
          'refresh-',
          'a1',
          'a2',
          'u-1',
          'Ada',
          'ada@example.com',
          'the-code',
          'example.com',
          'http',
          'fake-proof',
          'fake-thumbprint',
        ]) {
          expect(text, isNot(contains(secret)), reason: secret);
        }
        expect(rec.log, isNotEmpty);
      },
      proof: FakeProof(),
      dpop: true,
    );

    scenario(
      'with no sink installed nothing is reported and everything works',
      (rig, time) async {
        FespalierTelemetry.install(null);
        rec.log.clear();
        time.elapse(const Duration(minutes: 6));
        await rig.notifier.credential();
        await rig.notifier.signOut();
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.user),
        );
        expect(rec.log, isEmpty);
      },
    );
  });
}

/// [rec]'s log without the span numbers.
List<String> spans(RecordingTelemetry rec) => [
  for (final line in rec.log) line.replaceFirst(RegExp(r'^#\d+ '), ''),
];

/// A transport that records what it was sent, answers 503 the first time and then asks [inner].
final class _Flaky implements HttpTransport {
  _Flaky(this.inner);

  final HttpTransport inner;
  final List<TransportRequest> sent = [];
  int calls = 0;

  @override
  Future<TransportResponse> send(TransportRequest request) {
    sent.add(request);
    if (++calls == 1) return Future.value(fakeResponse(503));
    return inner.send(request);
  }
}

/// A retrier: sends again once on a 503, the way a RetryClient or a Dio retry interceptor does.
final class _RetryOnce implements HttpTransport {
  _RetryOnce(this.inner);

  final HttpTransport inner;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final first = await inner.send(request);
    if (first.statusCode != 503) return first;
    await first.body.drain<void>();
    return inner.send(request);
  }
}
