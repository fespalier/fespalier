// OidcEndpoints.discover on the document Authkestra's OpenID Provider serves (`authkestra-op` at
// 68a250f, `OidcDiscovery::from_config`, as examples/authkestra-op/server serves it): no preset is
// needed. The document below was read from that server; the end-to-end run is
// packages/fespalier_keypair_dpop/test/authkestra_op_test.dart.
import 'dart:convert';

import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _issuer = 'http://127.0.0.1:37989';

/// `OidcDiscovery::from_config(&config)` with [dpop] (`with_dpop_support()`) and [revocation]
/// (`with_revocation_endpoint(...)`), the two opt-ins a host makes.
Map<String, Object?> _document({bool dpop = true, bool revocation = true}) => {
  'issuer': _issuer,
  'authorization_endpoint': '$_issuer/authorize',
  'code_challenge_methods_supported': ['S256'],
  if (dpop)
    'dpop_signing_alg_values_supported': ['ES256', 'ES384', 'RS256', 'EdDSA'],
  'token_endpoint': '$_issuer/token',
  'jwks_uri': '$_issuer/jwks.json',
  'userinfo_endpoint': '$_issuer/userinfo',
  'scopes_supported': ['openid', 'profile', 'email', 'offline_access'],
  'response_types_supported': ['code'],
  'response_modes_supported': ['query'],
  'grant_types_supported': ['authorization_code', 'refresh_token'],
  'subject_types_supported': ['public'],
  'id_token_signing_alg_values_supported': ['EdDSA'],
  'token_endpoint_auth_methods_supported': [
    'client_secret_basic',
    'client_secret_post',
    'none',
  ],
  'claims_supported': ['sub', 'iss', 'aud', 'exp', 'iat', 'name', 'email'],
  if (revocation) 'revocation_endpoint': '$_issuer/revoke',
};

FakeTransport _serving(Map<String, Object?> document) => FakeTransport(
  (request, _) => fakeResponse(
    200,
    body: jsonEncode(document),
    headers: const {'content-type': 'application/json'},
  ),
);

void main() {
  test('discover reads authkestra-op with both opt-ins', () async {
    final transport = _serving(_document());
    final found = await OidcEndpoints.discover(
      Uri.parse(_issuer),
      transport: transport,
    );
    expect(
      transport.requests.single.request.uri,
      Uri.parse('$_issuer/.well-known/openid-configuration'),
    );
    expect(found.authorization, Uri.parse('$_issuer/authorize'));
    expect(found.token, Uri.parse('$_issuer/token'));
    expect(found.revocation, Uri.parse('$_issuer/revoke'));
    expect(found.endSession, isNull);
    expect(found.dpopAlgorithms, contains('ES256'));
  });

  test(
    'without the opt-ins: no revocation endpoint (sign-out is local) and no DPoP algorithms',
    () async {
      final found = await OidcEndpoints.discover(
        Uri.parse(_issuer),
        transport: _serving(_document(dpop: false, revocation: false)),
      );
      expect(found.authorization, Uri.parse('$_issuer/authorize'));
      expect(found.revocation, isNull);
      expect(found.dpopAlgorithms, isNull);
    },
  );

  test('an issuer with a trailing slash finds the same document', () async {
    final found = await OidcEndpoints.discover(
      Uri.parse('$_issuer/'),
      transport: _serving(_document()),
    );
    expect(found.token, Uri.parse('$_issuer/token'));
  });
}
