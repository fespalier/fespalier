// DpopProof under OidcBackend, against a server that checks every proof the way an authorization
// server does (verifyDpopProof, the jti seen once, the nonce, the clock, the key a code or a
// refresh token is bound to). No Riverpod and no network: a MockClient.
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/oidc.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

final issuer = Uri.parse('https://sso.example.com/realms/shop');
final redirectUri = Uri.parse('com.example.shop:/callback');
final endpoints = OidcEndpoints.keycloak(issuer);
const clientId = 'shop-app';

/// A JWT built at run time (a committed literal would be flagged by secret scanners).
String jwt(Map<String, Object?> claims) =>
    '${b64u(utf8.encode(jsonEncode({'alg': 'RS256', 'typ': 'JWT'})))}.'
    '${b64u(utf8.encode(jsonEncode(claims)))}.c2ln';

/// An authorization server that requires DPoP.
final class DpopServer {
  /// How far the server's clock is ahead of the device's.
  Duration skew = Duration.zero;

  /// When set, every proof must carry it, and a proof that does not is challenged.
  String? requiredNonce;

  /// Whether a clock problem comes with a `Date` header (Keycloak sends none).
  bool sendsDate = true;

  /// Whether a clock problem is `invalid_dpop_proof` (RFC 9449) or Keycloak's `invalid_request`.
  bool keycloakErrors = false;

  final Set<String> seen = {};
  final List<String> proofs = [];
  final List<Map<String, String>> forms = [];
  String? codeJkt;
  String? nonceOfAuthorizationRequest;
  int issued = 0;

  DateTime get now => clock.now().add(skew);

  http.Response _error(
    String code,
    String description, {
    Map<String, String> headers = const {},
  }) => http.Response(
    jsonEncode({'error': code, 'error_description': description}),
    400,
    headers: {'content-type': 'application/json', ...headers},
  );

  late final MockClient client = MockClient((request) async {
    final proof = request.headers['DPoP'];
    if (proof == null) {
      return _error('invalid_request', 'DPoP proof is missing');
    }
    proofs.add(proof);
    final DecodedDpopProof decoded;
    try {
      decoded = verifyDpopProof(
        proof,
        method: request.method,
        uri: request.url,
        nonce: requiredNonce,
        now: now,
      );
    } on DpopProofInvalid catch (e) {
      if (e.message.startsWith('nonce is')) {
        return _error(
          'use_dpop_nonce',
          'Authorization server requires nonce in DPoP proof',
          headers: {'dpop-nonce': requiredNonce!},
        );
      }
      if (e.message.startsWith('iat is')) {
        return _error(
          keycloakErrors ? 'invalid_request' : 'invalid_dpop_proof',
          'DPoP proof is not active',
          headers: {if (sendsDate) 'date': httpDate(now)},
        );
      }
      return _error('invalid_dpop_proof', e.message);
    }
    final jti = decoded.claims['jti']! as String;
    if (!seen.add(jti)) {
      return _error('invalid_request', 'DPoP proof has already been used');
    }
    final form = request.bodyFields;
    forms.add(form);
    final jkt = decoded.thumbprint;
    final nonceHeader = requiredNonce == null
        ? const <String, String>{}
        : {'dpop-nonce': requiredNonce!};
    if (form['grant_type'] == 'authorization_code') {
      if (codeJkt != null && codeJkt != jkt) {
        return _error(
          'invalid_request',
          'DPoP Proof public key thumbprint does not match dpop_jkt',
        );
      }
    } else if (form['grant_type'] == 'refresh_token') {
      if (!form['refresh_token']!.endsWith('.$jkt')) {
        return _error(
          'invalid_grant',
          "DPoP confirmation doesn't match DPoP proof",
        );
      }
    }
    issued++;
    return http.Response(
      jsonEncode({
        'access_token': jwt({
          'sub': 'u-1',
          'jti': 'a$issued',
          'cnf': {'jkt': jkt},
        }),
        'expires_in': 300,
        'refresh_expires_in': 1800,
        'refresh_token': 'refresh-$issued.$jkt',
        'token_type': 'DPoP',
        'id_token': jwt({
          'iss': issuer.toString(),
          'aud': clientId,
          'sub': 'u-1',
          'nonce': nonceOfAuthorizationRequest,
        }),
        'scope': 'openid profile email',
      }),
      200,
      headers: {'content-type': 'application/json', ...nonceHeader},
    );
  });
}

OidcBackend backend(
  DpopServer server,
  ProofOfPossession? proof, {
  List<Uri>? opened,
}) => OidcBackend(
  issuer: issuer,
  clientId: clientId,
  redirectUri: redirectUri,
  endpoints: endpoints,
  client: server.client,
  proof: proof,
  openBrowser: (url, redirect) async {
    opened?.add(url);
    server.nonceOfAuthorizationRequest = url.queryParameters['nonce'];
    server.codeJkt = url.queryParameters['dpop_jkt'];
    return redirect.replace(
      queryParameters: {
        'code': 'the-code',
        'state': url.queryParameters['state']!,
        'iss': issuer.toString(),
      },
    );
  },
);

void main() {
  late DpopServer server;
  late DpopProof dpop;
  setUp(() {
    server = DpopServer();
    dpop = DpopProof(signer: FakeDpopSigner());
  });

  Future<T> atT0<T>(Future<T> Function() body) =>
      withClock(Clock.fixed(t0), body);

  test(
    'signs in: the code is bound to the key, the exchange carries a proof, the session is bound',
    () async {
      await atT0(() async {
        final opened = <Uri>[];
        final session = await backend(
          server,
          dpop,
          opened: opened,
        ).signIn(const BrowserSignIn());
        expect(opened.single.queryParameters['dpop_jkt'], fakeThumbprint0);
        expect(session.tokens.isDpop, isTrue);
        expect(session.tokens.tokenType, 'DPoP');
        expect(session.binding, fakeThumbprint0);
        final claims = part(server.proofs.single, 1);
        expect(claims['htm'], 'POST');
        expect(claims['htu'], endpoints.token.toString());
        expect(
          claims.containsKey('ath'),
          isFalse,
          reason: 'never on a token request',
        );
      });
    },
  );

  test(
    'refreshes with a proof of the same key, and a new jti each time',
    () async {
      await atT0(() async {
        final oidc = backend(server, dpop);
        final session = await oidc.signIn(const BrowserSignIn());
        final again = await oidc.refresh(session);
        expect(again.binding, fakeThumbprint0);
        expect(again.tokens.refreshToken, endsWith('.$fakeThumbprint0'));
        final jtis = [for (final p in server.proofs) part(p, 1)['jti']];
        expect(jtis, hasLength(2));
        expect(jtis.toSet(), hasLength(2));
      });
    },
  );

  test(
    'answers a nonce challenge once, and keeps the nonce for the next request',
    () async {
      await atT0(() async {
        server.requiredNonce = 'server-nonce-1';
        final oidc = backend(server, dpop);
        final session = await oidc.signIn(const BrowserSignIn());
        expect(
          server.proofs,
          hasLength(2),
          reason: 'the challenged one and its retry',
        );
        expect(part(server.proofs[0], 1).containsKey('nonce'), isFalse);
        expect(part(server.proofs[1], 1)['nonce'], 'server-nonce-1');
        await oidc.refresh(session);
        expect(
          server.proofs,
          hasLength(3),
          reason: 'no new challenge: the nonce was kept',
        );
        expect(part(server.proofs[2], 1)['nonce'], 'server-nonce-1');
      });
    },
  );

  test(
    'corrects a device clock that is behind, once, from the Date header',
    () async {
      await atT0(() async {
        server.skew = const Duration(minutes: 3);
        final session = await backend(
          server,
          dpop,
        ).signIn(const BrowserSignIn());
        expect(session.tokens.isDpop, isTrue);
        expect(server.proofs, hasLength(2));
        expect(dpop.clockOffset, const Duration(minutes: 3));
        expect(
          part(server.proofs[1], 1)['iat'],
          t0.add(const Duration(minutes: 3)).millisecondsSinceEpoch ~/ 1000,
        );
      });
    },
  );

  test("corrects it for Keycloak's invalid_request, too", () async {
    await atT0(() async {
      server
        ..skew = const Duration(minutes: -2)
        ..keycloakErrors = true;
      await backend(server, dpop).signIn(const BrowserSignIn());
      expect(dpop.clockOffset, const Duration(minutes: -2));
    });
  });

  test(
    'a server with no Date header cannot correct it: the error says what happened',
    () async {
      await atT0(() async {
        server
          ..skew = const Duration(minutes: 3)
          ..keycloakErrors = true
          ..sendsDate = false;
        await expectLater(
          backend(server, dpop).signIn(const BrowserSignIn()),
          throwsA(
            isA<OidcException>().having(
              (e) => e.message,
              'message',
              'the token endpoint answered HTTP 400: invalid_request: DPoP proof is not active',
            ),
          ),
        );
        expect(
          server.proofs,
          hasLength(1),
          reason: 'not retried: nothing to correct with',
        );
        expect(dpop.clockOffset, Duration.zero);
      });
    },
  );

  test(
    'a proof sent twice is refused as a reused jti: what a RetryClient under the session would do',
    () async {
      await atT0(() async {
        final headers = await dpop.headers(
          method: 'POST',
          uri: endpoints.token,
        );
        final first = await server.client.post(
          endpoints.token,
          headers: headers,
          body: {
            'grant_type': 'refresh_token',
            'refresh_token': 'refresh-0.$fakeThumbprint0',
          },
        );
        expect(first.statusCode, 200);
        final second = await server.client.post(
          endpoints.token,
          headers: headers,
          body: {
            'grant_type': 'refresh_token',
            'refresh_token': 'refresh-0.$fakeThumbprint0',
          },
        );
        expect(second.statusCode, 400);
        expect(jsonDecode(second.body), {
          'error': 'invalid_request',
          'error_description': 'DPoP proof has already been used',
        });
        // A proof made for each attempt is fine.
        final third = await server.client.post(
          endpoints.token,
          headers: await dpop.headers(method: 'POST', uri: endpoints.token),
          body: {
            'grant_type': 'refresh_token',
            'refresh_token': 'refresh-0.$fakeThumbprint0',
          },
        );
        expect(third.statusCode, 200);
      });
    },
  );

  test(
    'sign-out rotates the key: the next sign-in is bound to a new one',
    () async {
      await atT0(() async {
        final oidc = backend(server, dpop);
        final first = await oidc.signIn(const BrowserSignIn());
        expect(first.binding, fakeThumbprint0);
        await dpop.reset();
        final second = await oidc.signIn(const BrowserSignIn());
        expect(second.binding, fakeThumbprint1);
        expect(server.codeJkt, fakeThumbprint1);
      });
    },
  );

  test(
    'a refresh token bound to a key that is gone is AuthRejected, in the server\'s words',
    () async {
      await atT0(() async {
        final oidc = backend(server, dpop);
        final session = await oidc.signIn(const BrowserSignIn());
        await dpop
            .reset(); // the key is gone: a restored backup, a wiped keychain
        await expectLater(
          oidc.refresh(session),
          throwsA(
            isA<AuthRejected>()
                .having((e) => e.error, 'error', 'invalid_grant')
                .having(
                  (e) => e.description,
                  'description',
                  "DPoP confirmation doesn't match DPoP proof",
                ),
          ),
        );
      });
    },
  );

  test(
    'no jti is ever used twice, across sign-in, nonce retries, clock retries and refreshes',
    () async {
      await atT0(() async {
        server.requiredNonce = 'n';
        final oidc = backend(server, dpop);
        final session = await oidc.signIn(
          const BrowserSignIn(),
        ); // a nonce challenge, one retry
        server.skew = const Duration(minutes: 3);
        await oidc.refresh(session); // a clock correction, one retry
        final jtis = [
          for (final p in server.proofs) part(p, 1)['jti']! as String,
        ];
        expect(jtis, hasLength(4));
        expect(jtis.toSet(), hasLength(jtis.length));
      });
    },
  );
}
