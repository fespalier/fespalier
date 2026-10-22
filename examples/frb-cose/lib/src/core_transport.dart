import 'dart:convert';

import 'package:fespalier_cratestack/fespalier_cratestack.dart';

import 'core.dart';
import 'notes.dart';

/// A [CrateStackTransport] over the Rust core: each call is one call of the core, which seals it with the device
/// key, sends it and opens the answer.
///
/// **Where signing sits.** In the core, once per attempt. An intent stores the call as JSON and sends it again, so
/// every attempt is a new sealed message over the same arguments under the same `Idempotency-Key`: the core's
/// registration and its sealing happen inside `send`, never before it.
///
/// **What it answers.** The core's answer and failure, read as CrateStack reads a server's answer:
///
/// | The core says                                              | [send] throws                            |
/// | ---------------------------------------------------------- | ---------------------------------------- |
/// | an unsigned `401`                                          | [CrateStackUnauthenticated]              |
/// | an unsigned `400`, `413`, `415`, `426` (the contract too)  | [CrateStackRefused], code `HTTP_<n>`     |
/// | any other unsigned answer                                  | [CrateStackOffline], the same key        |
/// | a sealed answer that is not 2xx                            | by its status and envelope (`fromResponse`) |
/// | a sealed `2xx`                                             | nothing: the body is the result          |
/// | `Unverified`, `Seal`, `Registration`, `Transport`          | [CrateStackOffline], the same key        |
/// | `BadInput`, or an op the core does not have                | [ArgumentError]: nothing was sent        |
///
/// A failure that is not the server's word is [CrateStackOffline], never [CrateStackUnavailable]: the write may have
/// landed, and a new key would run it twice. The cause of an offline failure is the core's kind, never its text.
final class CoreTransport implements CrateStackTransport {
  /// A transport over [core].
  CoreTransport(this._core);

  final NotesCore _core;

  @override
  Future<Object?> send(CrateStackCall call, {String? idempotencyKey}) async {
    if (call is! RpcCall) {
      throw UnsupportedError('the Rust core speaks the RPC transport only');
    }
    if (!coreOps.contains(call.opId)) {
      throw ArgumentError.value(call.opId, 'opId', 'not an op of the core');
    }
    final CoreAnswer answer;
    try {
      answer = await _core.call(
        op: call.opId,
        argsJson: jsonEncode(call.input),
        idempotencyKey: idempotencyKey ?? '',
      );
    } on CoreError catch (error) {
      throw coreFailure(error);
    }
    final body = _body(answer.bodyJson);
    if (answer.status >= 200 && answer.status < 300) return body;
    throw CrateStackFailure.fromResponse(
          status: answer.status,
          body: body,
          retryAfter: answer.retryAfter != null,
          cause: answer.status,
        ) ??
        CrateStackOffline(answer.status);
  }
}

/// What a core failure means to CrateStack: the table of [CoreTransport]. Its message is never read: an offline
/// failure keeps the core's kind as its cause, and a refusal carries only a status.
Object coreFailure(CoreError error) => switch (error.kind) {
  CoreErrorKind.unsigned => _unsigned(error.status ?? 0),
  CoreErrorKind.badInput => ArgumentError(
    'the Rust core refused the call: its op or its arguments are wrong',
  ),
  CoreErrorKind.unverified ||
  CoreErrorKind.seal ||
  CoreErrorKind.transport ||
  CoreErrorKind.registration => CrateStackOffline(error.kind),
};

CrateStackFailure _unsigned(int status) => switch (status) {
  401 => const CrateStackUnauthenticated(),
  400 ||
  413 ||
  415 ||
  426 => CrateStackRefused(status: status, code: 'HTTP_$status', message: ''),
  _ => CrateStackOffline(status),
};

/// The body of an answer, decoded; a body that is not JSON is no body.
Object? _body(String json) {
  try {
    return jsonDecode(json);
  } on FormatException {
    return null;
  }
}
