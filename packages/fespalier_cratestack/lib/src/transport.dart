import 'package:fespalier/fespalier.dart' show Provider;

/// One CrateStack call, fully formed and replayable: what an intent stores and sends again.
///
/// It is JSON-encodable ([toJson]), so a call can wait in a `LocalStore` and be sent after a
/// restart, byte for byte as it was first.
sealed class CrateStackCall {
  /// A call.
  const CrateStackCall();

  /// The call as a JSON-encodable map.
  Map<String, Object?> toJson();

  /// The call [toJson] wrote. Throws a [FormatException] for anything else.
  static CrateStackCall fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException(
        'fespalier_cratestack: a call is a JSON object',
      );
    }
    switch (json['k']) {
      case 'rpc':
        final op = json['op'];
        if (op is! String) {
          throw const FormatException(
            'fespalier_cratestack: an rpc call needs an "op"',
          );
        }
        return RpcCall(op, json['in']);
      case 'rest':
        final method = json['method'];
        final path = json['path'];
        if (method is! String || path is! String) {
          throw const FormatException(
            'fespalier_cratestack: a rest call needs a method and a path',
          );
        }
        final query = json['query'];
        return RestCall(
          method,
          path,
          query: query is Map<String, Object?> ? query : const {},
          body: json['body'],
        );
    }
    throw FormatException(
      'fespalier_cratestack: unknown call kind ${json['k']}',
    );
  }
}

/// `POST /rpc/{opId}` (CrateStack's RPC transport, the recommended one).
final class RpcCall extends CrateStackCall {
  /// An RPC call of [opId] with the wire [input]; it must be JSON-encodable to be queued.
  const RpcCall(this.opId, this.input);

  /// The operation id as the generated client names it, e.g. `cancelOrder` or `model.Order.update`.
  final String opId;

  /// The wire input (`args.toWire()`), sent byte-identical on every attempt.
  final Object? input;

  @override
  Map<String, Object?> toJson() => {'k': 'rpc', 'op': opId, 'in': input};

  @override
  String toString() => 'RpcCall($opId)';
}

/// A REST call (CrateStack's default transport): method, path, query and body.
final class RestCall extends CrateStackCall {
  /// A REST call; it must be JSON-encodable to be queued.
  const RestCall(this.method, this.path, {this.query = const {}, this.body});

  /// The HTTP method, e.g. `POST`.
  final String method;

  /// The path, relative to the client's base path.
  final String path;

  /// The query parameters.
  final Map<String, Object?> query;

  /// The body, sent byte-identical on every attempt.
  final Object? body;

  @override
  Map<String, Object?> toJson() => {
    'k': 'rest',
    'method': method,
    'path': path,
    if (query.isNotEmpty) 'query': query,
    'body': body,
  };

  @override
  String toString() => 'RestCall($method $path)';
}

/// What sends a [CrateStackCall]: the generated client's adapter behind a thin wrapper the app writes.
///
/// The generated runtime types live in each app's own generated package, so this package cannot
/// import them. This is the minimum it needs.
abstract interface class CrateStackTransport {
  /// Sends [call] once (never retried here) with [idempotencyKey] as the `Idempotency-Key`
  /// header when given, and returns the decoded output. Throws whatever the client throws;
  /// `CrateStackErrors` classifies it.
  Future<Object?> send(CrateStackCall call, {String? idempotencyKey});
}

/// The transport the app provides:
/// `crateStackTransport.overrideWith((ref) => MyTransport(ref.watch(adapterProvider)))`.
///
/// Only queued intents and the row-sync protocol use it; online reads keep using the generated
/// client directly.
final crateStackTransport = Provider<CrateStackTransport>(
  (ref) => throw UnimplementedError(
    'fespalier_cratestack: override crateStackTransport with a CrateStackTransport '
    'that wraps your generated client (see the README).',
  ),
);
