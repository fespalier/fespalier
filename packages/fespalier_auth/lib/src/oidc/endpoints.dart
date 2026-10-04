import 'dart:convert';

import 'package:http/http.dart' as http;

import 'exception.dart';

/// An OpenID provider's endpoints (since 0.9.0).
final class OidcEndpoints {
  /// Endpoints written out by hand, when the provider's discovery document is not wanted.
  const OidcEndpoints({
    required this.authorization,
    required this.token,
    this.revocation,
    this.endSession,
    this.dpopAlgorithms,
  });

  /// Keycloak's endpoints from the realm's issuer (`https://host/realms/shop`): the usual
  /// `protocol/openid-connect/auth`, `token`, `revoke` and `logout`. It makes no discovery
  /// request, so a cold start's first refresh does not pay one.
  factory OidcEndpoints.keycloak(Uri issuer) {
    final base = issuer.toString().replaceFirst(RegExp(r'/+$'), '');
    Uri at(String name) => Uri.parse('$base/protocol/openid-connect/$name');
    return OidcEndpoints(
      authorization: at('auth'),
      token: at('token'),
      revocation: at('revoke'),
      endSession: at('logout'),
    );
  }

  /// The authorization endpoint the browser opens.
  final Uri authorization;

  /// Where a code, and then a refresh token, is exchanged for tokens.
  final Uri token;

  /// RFC 7009 token revocation, when the provider has one.
  final Uri? revocation;

  /// OpenID Connect's end-session endpoint, when the provider has one.
  final Uri? endSession;

  /// `dpop_signing_alg_values_supported`, when the provider says.
  final List<String>? dpopAlgorithms;

  /// Reads `<issuer>/.well-known/openid-configuration`, and checks that the document's `issuer` is
  /// [issuer] (a document served for another issuer is refused).
  static Future<OidcEndpoints> discover(
    Uri issuer, {
    http.Client? client,
  }) async {
    final base = issuer.toString().replaceFirst(RegExp(r'/+$'), '');
    final url = Uri.parse('$base/.well-known/openid-configuration');
    final own = client == null;
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient.get(
        url,
        headers: {'Accept': 'application/json'},
      );
      if (response.statusCode != 200) {
        throw OidcException(
          'discovery at $url failed with HTTP ${response.statusCode}',
        );
      }
      final Object? json;
      try {
        json = jsonDecode(response.body);
      } on FormatException {
        throw OidcException('discovery at $url did not answer JSON');
      }
      if (json is! Map<String, Object?>) {
        throw OidcException('discovery at $url did not answer a JSON object');
      }
      final Map<String, Object?> doc = json;
      final found = doc['issuer'];
      if (found is! String || found.replaceFirst(RegExp(r'/+$'), '') != base) {
        throw OidcException(
          "the discovery document's issuer $found is not $issuer",
        );
      }
      Uri? endpoint(String key) {
        final value = doc[key];
        return value is String ? Uri.parse(value) : null;
      }

      final authorization = endpoint('authorization_endpoint');
      final token = endpoint('token_endpoint');
      if (authorization == null || token == null) {
        throw OidcException(
          'discovery at $url has no authorization_endpoint or token_endpoint',
        );
      }
      final algs = doc['dpop_signing_alg_values_supported'];
      return OidcEndpoints(
        authorization: authorization,
        token: token,
        revocation: endpoint('revocation_endpoint'),
        endSession: endpoint('end_session_endpoint'),
        dpopAlgorithms: algs is List<Object?>
            ? [
                for (final a in algs)
                  if (a is String) a,
              ]
            : null,
      );
    } finally {
      if (own) httpClient.close();
    }
  }
}
