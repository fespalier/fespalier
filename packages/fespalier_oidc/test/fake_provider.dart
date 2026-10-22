// A fake provider for the tests: a Keycloak that answers discovery and the token endpoint from a
// FakeTransport, remembers what it was sent, and a browser that completes the sign-in.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';

import 'support.dart';

final issuer = Uri.parse('https://sso.example.com/realms/shop');
final redirectUri = Uri.parse('com.example.shop:/callback');
final endpoints = OidcEndpoints.keycloak(issuer);
const clientId = 'shop-app';

TokenCredential tokensOf(AuthSession session) =>
    session.credential as TokenCredential;

/// What a fake Keycloak is, and what it saw.
final class Server {
  /// Every request it was sent, oldest first (a test may clear it).
  final List<SentRequest> requests = [];

  /// The `nonce` the last authorization URL carried: the ID token echoes it.
  String? nonce;

  Map<String, Object?> idClaims = {};
  Map<String, Object?> accessClaims = {};
  Map<String, Object?> extra = {};
  int status = 200;
  Object? body;
  Object? Function(SentRequest request)? answer;
  int tokens = 0;

  /// The discovery document: a map (or a string, as it is) to answer; null for the default.
  Object? discovery;
  int discoveryStatus = 200;

  /// Headers added to every token endpoint answer.
  Map<String, String> tokenHeaders = {};

  Map<String, Object?> tokenResponse() {
    tokens++;
    return {
      'access_token': jwt({
        'sub': 'u-1',
        'realm_access': {
          'roles': ['admin', 'offline_access'],
        },
        'resource_access': {
          clientId: {
            'roles': ['buyer'],
          },
          'account': {
            'roles': ['manage-account'],
          },
        },
        'jti': 'a$tokens',
        ...accessClaims,
      }),
      'expires_in': 300,
      'refresh_expires_in': 1800,
      'refresh_token': 'refresh-$tokens',
      'token_type': 'Bearer',
      'id_token': jwt({
        'iss': issuer.toString(),
        'aud': clientId,
        'sub': 'u-1',
        'name': 'Ada Example',
        'email': 'ada@example.com',
        'nonce': nonce,
        'iat': tokens,
        ...idClaims,
      }),
      'scope': 'openid profile email',
      ...extra,
    };
  }

  Map<String, Object?> defaultDiscovery() => {
    'issuer': issuer.toString(),
    'authorization_endpoint': endpoints.authorization.toString(),
    'token_endpoint': endpoints.token.toString(),
    'revocation_endpoint': endpoints.revocation.toString(),
    'end_session_endpoint': endpoints.endSession.toString(),
    'dpop_signing_alg_values_supported': ['ES256', 'RS256'],
  };

  /// While set, the token endpoint waits for it before it answers (a request in flight).
  Completer<void>? gate;

  /// Answers one request, as the transport does.
  Future<TransportResponse> handle(
    TransportRequest request,
    Uint8List bytes,
  ) async {
    final sent = SentRequest(request, bytes);
    requests.add(sent);
    String encode(Object? payload) =>
        payload is String ? payload : jsonEncode(payload);
    if (request.uri.path.endsWith('openid-configuration')) {
      return fakeResponse(
        discoveryStatus,
        body: encode(discovery ?? defaultDiscovery()),
      );
    }
    final pending = gate;
    if (pending != null) await pending.future;
    final custom = answer?.call(sent);
    final payload = custom ?? body ?? tokenResponse();
    return fakeResponse(
      status,
      body: jsonEncode(payload),
      headers: {'content-type': 'application/json', ...tokenHeaders},
    );
  }

  late final FakeTransport transport = FakeTransport(handle);

  List<SentRequest> get posts => [
    for (final r in requests)
      if (r.method == 'POST') r,
  ];

  List<SentRequest> get gets => [
    for (final r in requests)
      if (r.method == 'GET') r,
  ];
}

/// A browser that is sent back to the redirect with [params] over a good code and state.
Future<Uri> Function(Uri, Uri) browser(
  Server server, {
  Map<String, String> params = const {},
  Set<String> without = const {},
  List<Uri>? opened,
}) => (url, redirect) async {
  opened?.add(url);
  server.nonce = url.queryParameters['nonce'];
  final query = {
    'code': 'the-code',
    'state': url.queryParameters['state']!,
    'iss': issuer.toString(),
    ...params,
  }..removeWhere((k, _) => without.contains(k));
  return redirect.replace(queryParameters: query);
};

OidcBackend backend(
  Server server, {
  Future<Uri> Function(Uri, Uri)? openBrowser,
  OidcEndpoints? known,
  ProofOfPossession? proof,
  bool bindCodeToKey = true,
  int seed = 1,
  List<String> scopes = const ['openid', 'profile', 'email'],
  HttpTransport? transport,
}) => OidcBackend(
  issuer: issuer,
  clientId: clientId,
  redirectUri: redirectUri,
  openBrowser: openBrowser ?? browser(server),
  endpoints: known ?? endpoints,
  transport: transport ?? server.transport,
  proof: proof,
  bindCodeToKey: bindCodeToKey,
  scopes: scopes,
  random: Random(seed),
);

/// A backend that discovers its endpoints (none known).
OidcBackend discovering(Server server, {ProofOfPossession? proof}) =>
    OidcBackend(
      issuer: issuer,
      clientId: clientId,
      redirectUri: redirectUri,
      openBrowser: browser(server),
      transport: server.transport,
      proof: proof,
      random: Random(1),
    );
