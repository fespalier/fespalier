import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'cbor.dart';
import 'errors.dart';

/// The binding version, the first element of the external AAD. Version 2 (cratestack 0.15.2)
/// binds the called op's contract digest where version 1 bound the whole schema's.
const int bindingVersion = 2;

/// What a response was made for: the request it answers (kind 1 for a signed request, the
/// digest is `SHA-256` of the request's COSE bytes), and the HTTP status.
final class ResponseLink {
  /// A link to a signed request ([requestDigest] from [requestDigestOf]).
  const ResponseLink({
    required this.requestDigest,
    required this.status,
    this.requestKind = 1,
  });

  /// 0 for an unsigned request, 1 for a signed one.
  final int requestKind;

  /// 32 bytes.
  final Uint8List requestDigest;

  /// The HTTP status of the response.
  final int status;
}

/// The request context a message is bound to: encoded as the external AAD, never sent. Both
/// sides rebuild it from their own context, and any disagreement is a 401.
final class CoseBinding {
  /// A request binding (without [response]) or a response binding (with it).
  const CoseBinding({
    required this.audience,
    required this.method,
    required this.route,
    required this.contractSha,
    this.pathParams = const <String>[],
    this.query,
    this.payloadType = 'application/cbor',
    this.idempotencyKey,
    this.ifMatch,
    this.response,
  });

  /// The recipient's configured id; empty is refused.
  final String audience;

  /// `POST` for every RPC call.
  final String method;

  /// The RPC op id (`procedure.ping`); a REST route template otherwise.
  final String route;

  /// REST: the matched path values in template order; RPC: none.
  final List<String> pathParams;

  /// The query string without `?`; null (or empty) when there is none.
  final String? query;

  /// The called op's contract digest: 32 bytes.
  final Uint8List contractSha;

  /// The payload's media type inside the envelope.
  final String payloadType;

  /// The `Idempotency-Key` header exactly as sent, or null.
  final String? idempotencyKey;

  /// The `If-Match` header exactly as sent, or null.
  final String? ifMatch;

  /// Set for a response; null for a request.
  final ResponseLink? response;

  /// The same context as a response with [link].
  CoseBinding answeredBy(ResponseLink link) => CoseBinding(
    audience: audience,
    method: method,
    route: route,
    contractSha: contractSha,
    pathParams: pathParams,
    query: query,
    payloadType: payloadType,
    idempotencyKey: idempotencyKey,
    ifMatch: ifMatch,
    response: link,
  );

  /// The same context with another contract digest.
  CoseBinding withContract(Uint8List sha) => CoseBinding(
    audience: audience,
    method: method,
    route: route,
    contractSha: sha,
    pathParams: pathParams,
    query: query,
    payloadType: payloadType,
    idempotencyKey: idempotencyKey,
    ifMatch: ifMatch,
    response: response,
  );

  /// Whether [other] differs from this in anything but the contract digest.
  bool differsBeyondDigest(CoseBinding other) =>
      audience != other.audience ||
      method != other.method ||
      route != other.route ||
      !_sameList(pathParams, other.pathParams) ||
      (query ?? '') != (other.query ?? '') ||
      payloadType != other.payloadType ||
      idempotencyKey != other.idempotencyKey ||
      ifMatch != other.ifMatch ||
      (response == null) != (other.response == null) ||
      (response != null &&
          (response!.requestKind != other.response!.requestKind ||
              response!.status != other.response!.status ||
              !_sameBytes(
                response!.requestDigest,
                other.response!.requestDigest,
              )));
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// `SHA-256` of a signed request's exact COSE bytes: the digest a response to it is bound to.
Uint8List requestDigestOf(List<int> sealedRequest) =>
    Uint8List.fromList(sha256.convert(sealedRequest).bytes);

/// The external AAD for [bind] (version 2): a 9-element array for a request, 12 for a response,
/// definite and shortest-form. An empty audience is [CoseMisuse]: it binds no recipient.
Uint8List externalAad(CoseBinding bind) {
  if (bind.audience.isEmpty) {
    throw const CoseMisuse(
      'an empty audience binds no recipient; configure the service id',
    );
  }
  if (bind.contractSha.length != 32) {
    throw const CoseMisuse('a contract digest is 32 bytes');
  }
  final response = bind.response;
  if (response != null && response.requestDigest.length != 32) {
    throw const CoseMisuse('a request digest is 32 bytes');
  }
  final query = bind.query;
  final out = CborWriter()
    ..head(majorArray, response == null ? 9 : 12)
    ..head(majorUint, bindingVersion)
    ..tstr(bind.audience)
    ..tstr(bind.method)
    ..tstr(bind.route)
    ..head(majorArray, bind.pathParams.length);
  for (final value in bind.pathParams) {
    out.tstr(value);
  }
  // A missing and an empty query bind the same: `null`.
  if (query == null || query.isEmpty) {
    out.nul();
  } else {
    out.tstr(query);
  }
  out
    ..bstr(bind.contractSha)
    ..tstr(bind.payloadType)
    ..head(majorArray, 2);
  for (final value in [bind.idempotencyKey, bind.ifMatch]) {
    if (value == null) {
      out.nul();
    } else {
      out.tstr(value);
    }
  }
  if (response != null) {
    out
      ..head(majorUint, response.requestKind)
      ..bstr(response.requestDigest)
      ..head(majorUint, response.status);
  }
  return out.toBytes();
}
