import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:http/http.dart' as http;

import 'contracts.g.dart';
import 'cose/cose.dart';
import 'payload.dart';

/// Where the server is and which key answers for it: pinned in the build, never learned from
/// the network.
final class CoseConfig {
  /// A server at [baseUrl] that binds [audience] into every message and seals every answer with
  /// [serverKey].
  CoseConfig({
    required this.baseUrl,
    required this.audience,
    required this.serverKey,
  });

  /// From the `--dart-define`s of a build: `COSE_SERVER_URL`, `COSE_AUDIENCE` and
  /// `COSE_SERVER_JWK` (the `server_public_jwk` the server prints on startup).
  factory CoseConfig.fromEnvironment() {
    const jwk = String.fromEnvironment('COSE_SERVER_JWK');
    if (jwk.isEmpty) {
      throw StateError(
        'Pin the server key: start the server (cose-demo-server --listen 127.0.0.1:8787) and '
        'build with --dart-define=COSE_SERVER_JWK=\'<its server_public_jwk>\'.',
      );
    }
    return CoseConfig.fromJwk(
      baseUrl: Uri.parse(
        const String.fromEnvironment(
          'COSE_SERVER_URL',
          defaultValue: 'http://127.0.0.1:8787',
        ),
      ),
      audience: const String.fromEnvironment(
        'COSE_AUDIENCE',
        defaultValue: coseAudience,
      ),
      jwk: jwk,
    );
  }

  /// From the server's public key as the JSON text of a JWK.
  factory CoseConfig.fromJwk({
    required Uri baseUrl,
    required String audience,
    required String jwk,
  }) {
    final map = (jsonDecode(jwk) as Map<String, Object?>)
        .cast<String, String>();
    return CoseConfig(
      baseUrl: baseUrl,
      audience: audience,
      serverKey: Esp256VerifyKey.jwk(map),
    );
  }

  /// The server's origin; `/rpc/<op>` is appended.
  final Uri baseUrl;

  /// The id the server binds into every message (its configured name, not its host).
  final String audience;

  /// The key every answer is checked against.
  final CoseVerifyKey serverKey;
}

/// A [CrateStackTransport] that seals every call as a COSE_Sign1 message with the device key and
/// opens the sealed answer, for the server in `examples/cose/server`.
///
/// **Where signing sits.** Inside `send`, once per attempt, and nowhere else. An intent stores
/// the call as JSON and sends it again after a failure or a restart; every attempt is therefore
/// a *new message* (a fresh `iat` and `cti`, so the server's replay check never sees the same
/// bytes twice) over the *same payload* (the call's input, encoded the same way) under the
/// *same* `Idempotency-Key`, which the signature binds. Signing earlier, and storing the signed
/// bytes, would make a retry a replay (a 401) after the first attempt.
///
/// **What it answers.** A sealed answer is opened with the pinned server key and the response
/// binding (the request's own digest, the status), and its CBOR payload decoded. Everything the
/// server did not seal is a refusal read by its status, never an answer:
///
/// | The server says                                 | [send] throws                         |
/// | ----------------------------------------------- | ------------------------------------- |
/// | an unsigned `401` (any request it refuses)      | [CrateStackUnauthenticated]           |
/// | `415` (a COSE body to the plain op), `426`, `4xx` | [CrateStackRefused] with its code   |
/// | a sealed `4xx` (a registered device's refusal)  | [CrateStackRefused]                   |
/// | `5xx`                                           | [CrateStackUnavailable]               |
/// | a sealed answer that does not open              | [CrateStackOffline], the same key     |
/// | no answer, or a page that is not the server's   | [CrateStackOffline]                   |
///
/// A sealed answer that does not open is [CrateStackOffline] and not [CrateStackUnavailable] on
/// purpose: the write may have landed, and `Unavailable` would move the intent to the next
/// idempotency key, risking a second write.
final class CoseTransport implements CrateStackTransport {
  /// A transport for [config] sealing with [sealer].
  ///
  /// [beforeSigned] runs before every signed call and may throw a [CrateStackFailure] to stop
  /// it: the app uses it to register the device key before the first one. [ops] is the
  /// contract table; the default is the generated one.
  CoseTransport({
    required this.config,
    required this.sealer,
    required this._client,
    this.beforeSigned,
    this._ops = coseOps,
    int Function()? nowSeconds,
  }) : _opener = CoseOpener([config.serverKey], nowSeconds: nowSeconds);

  /// The server.
  final CoseConfig config;

  /// Seals with the device key.
  final CoseSealer sealer;

  /// Runs before every signed call.
  final Future<void> Function()? beforeSigned;

  final http.Client _client;
  final Map<String, OpContract> _ops;
  final CoseOpener _opener;

  @override
  Future<Object?> send(CrateStackCall call, {String? idempotencyKey}) async {
    if (call is! RpcCall) {
      throw UnsupportedError('this server speaks the RPC transport only');
    }
    final contract = _ops[call.opId];
    if (contract == null) {
      throw ArgumentError.value(call.opId, 'opId', 'not an op of the contract');
    }
    // `args` is how the generated RPC input wraps a procedure's arguments.
    final payload = encodePayload({'args': call.input});
    final uri = config.baseUrl.resolve('/rpc/${call.opId}');
    if (!contract.signed) {
      return await _plain(uri, contract, payload);
    }
    await beforeSigned?.call();

    final bind = CoseBinding(
      audience: config.audience,
      method: 'POST',
      route: call.opId,
      contractSha: _unhex(contract.digest),
      idempotencyKey: idempotencyKey,
    );
    final request = await sealer.sealRequest(payload, bind);
    final http.Response response;
    try {
      response = await _client.post(
        uri,
        headers: {
          'content-type': coseContentType,
          'accept': coseContentType,
          contractHeader: contract.selector,
          'idempotency-key': ?idempotencyKey,
        },
        body: request,
      );
    } on Object catch (error) {
      throw CrateStackOffline(error);
    }
    if (_isCose(response)) {
      final answered = bind.answeredBy(
        ResponseLink(
          requestDigest: requestDigestOf(request),
          status: response.statusCode,
        ),
      );
      final Object? body;
      try {
        body = decodePayload(
          _opener.openResponse(response.bodyBytes, answered).payload,
        );
      } on Object catch (error) {
        // Not the server's answer, or damaged on the way: the call may have landed.
        throw CrateStackOffline('the sealed answer did not open: $error');
      }
      return _result(response, body);
    }
    // Not sealed: the layer's own refusal. Whatever it says, it is not an answer to a signed call.
    final failure = _refusal(response);
    throw failure ??
        const CrateStackOffline('an unsealed answer to a signed request');
  }

  Future<Object?> _plain(
    Uri uri,
    OpContract contract,
    Uint8List payload,
  ) async {
    final http.Response response;
    try {
      response = await _client.post(
        uri,
        headers: {
          'content-type': 'application/cbor',
          'accept': 'application/cbor',
          contractHeader: contract.selector,
        },
        body: payload,
      );
    } on Object catch (error) {
      throw CrateStackOffline(error);
    }
    final failure = _refusal(response);
    if (failure != null) throw failure;
    try {
      return decodePayload(response.bodyBytes);
    } on PayloadFormatException catch (error) {
      throw CrateStackOffline(error);
    }
  }

  Object? _result(http.Response response, Object? body) {
    if (response.statusCode >= 200 && response.statusCode < 300) return body;
    throw CrateStackFailure.fromResponse(
          status: response.statusCode,
          body: body,
          contentType: response.headers['content-type'],
        ) ??
        const CrateStackOffline(
          'a status that is neither a result nor an error',
        );
  }

  CrateStackFailure? _refusal(http.Response response) {
    Object? body;
    final type = response.headers['content-type']?.toLowerCase() ?? '';
    try {
      body = type.contains('json')
          ? jsonDecode(utf8.decode(response.bodyBytes))
          : type.contains('cbor')
          ? decodePayload(response.bodyBytes)
          : null;
    } on Object {
      body = null;
    }
    return CrateStackFailure.fromResponse(
      status: response.statusCode,
      body: body,
      contentType: type,
    );
  }

  static bool _isCose(http.Response response) =>
      (response.headers['content-type'] ?? '').toLowerCase().startsWith(
        'application/cose',
      );
}

Uint8List _unhex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}
