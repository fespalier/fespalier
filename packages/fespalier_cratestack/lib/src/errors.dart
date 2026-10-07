import 'package:fespalier/fespalier.dart' show Provider;

/// Why a CrateStack call did not succeed, classified by what it means for a retry and a cache.
sealed class CrateStackFailure implements Exception {
  /// A failure.
  const CrateStackFailure();

  /// The failure of an answer that has CrateStack's error envelope (`code`, `message`, `details`)
  /// and an HTTP [status]: the status and code table.
  ///
  /// `401` is [CrateStackUnauthenticated]; `409` is [CrateStackInFlight] with [retryAfter] and a
  /// [CrateStackConflict] without; any other `4xx` is [CrateStackRefused]; anything else (`5xx`,
  /// a status that is no error) is [CrateStackUnavailable].
  factory CrateStackFailure.fromEnvelope({
    required int status,
    required String code,
    required String message,
    Object? details,
    bool retryAfter = false,
  }) {
    if (status == 401) return const CrateStackUnauthenticated();
    if (status == 409) {
      return retryAfter
          ? const CrateStackInFlight()
          : CrateStackConflict(code: code, message: message);
    }
    if (status >= 400 && status < 500) {
      return CrateStackRefused(
        status: status,
        code: code,
        message: message,
        details: details,
      );
    }
    return CrateStackUnavailable(status: status, code: code);
  }

  /// The failure of an HTTP answer, or null when [status] is a success with a body that is no web
  /// page. A [body] that is a map with a string `code` and `message` is CrateStack's envelope
  /// ([CrateStackFailure.fromEnvelope]). Without one, a `502`, `503`, `504` or `511`, and any page
  /// of type `text/html` (a gateway's or a captive portal's, even with a `200`), is
  /// [CrateStackOffline]: nobody that knows CrateStack answered, so the call may have landed. A
  /// bare `401` is unauthenticated, a bare `4xx` is refused with the code `HTTP_<status>`, a bare
  /// `5xx` is [CrateStackUnavailable].
  static CrateStackFailure? fromResponse({
    required int status,
    Object? body,
    String? contentType,
    bool retryAfter = false,
    Object? cause,
  }) {
    if (body is Map<Object?, Object?>) {
      final code = body['code'];
      final message = body['message'];
      if (code is String && message is String) {
        return CrateStackFailure.fromEnvelope(
          status: status,
          code: code,
          message: message,
          details: body['details'],
          retryAfter: retryAfter,
        );
      }
    }
    final isPage =
        contentType != null && contentType.toLowerCase().contains('text/html');
    if (isPage ||
        status == 502 ||
        status == 503 ||
        status == 504 ||
        status == 511) {
      return CrateStackOffline(cause ?? 'HTTP $status');
    }
    if (status >= 200 && status < 300) return null;
    if (status == 401) return const CrateStackUnauthenticated();
    if (status == 409) {
      return retryAfter
          ? const CrateStackInFlight()
          : const CrateStackConflict(code: 'HTTP_409', message: '');
    }
    if (status >= 400 && status < 500) {
      return CrateStackRefused(
        status: status,
        code: 'HTTP_$status',
        message: '',
      );
    }
    return CrateStackUnavailable(status: status);
  }
}

/// No answer: no network, a dropped connection, a timeout, or a gateway or captive-portal page
/// (an HTML `200`, or a `502`, `503`, `504` or `511` without a CrateStack envelope). The call may
/// have landed.
///
/// Only this one makes a read fall back to the store, and it keeps an intent's key.
final class CrateStackOffline extends CrateStackFailure {
  /// An offline failure caused by [cause] (what the client threw).
  const CrateStackOffline([this.cause]);

  /// What the client threw, if anything. Never sent to telemetry.
  final Object? cause;

  @override
  String toString() => 'CrateStackOffline';
}

/// The server answered and decided: a refusal (`4xx`). [code] is the wire code, [message] the
/// server's text (never shown to telemetry: it may quote a value), [details] as sent.
final class CrateStackRefused extends CrateStackFailure {
  /// A refusal.
  const CrateStackRefused({
    required this.status,
    required this.code,
    required this.message,
    this.details,
  });

  /// The HTTP status.
  final int status;

  /// The wire code, e.g. `VALIDATION_ERROR`.
  final String code;

  /// The server's message.
  final String message;

  /// The `details` as sent; its shape is the server's.
  final Object? details;

  @override
  String toString() => 'CrateStackRefused($status $code)';
}

/// The server answered with a stored failure (`5xx`, an unreadable envelope): moves an intent to
/// its next key.
final class CrateStackUnavailable extends CrateStackFailure {
  /// A server failure.
  const CrateStackUnavailable({required this.status, this.code});

  /// The HTTP status.
  final int status;

  /// The wire code, when the answer had an envelope.
  final String? code;

  @override
  String toString() => 'CrateStackUnavailable($status)';
}

/// `409` with `Retry-After`: the same idempotency key is being answered now. Same key, try later.
final class CrateStackInFlight extends CrateStackFailure {
  /// An in-flight failure.
  const CrateStackInFlight();

  @override
  String toString() => 'CrateStackInFlight';
}

/// `401`: the session is being renewed (fespalier_auth refreshes lazily). Same key, try later.
final class CrateStackUnauthenticated extends CrateStackFailure {
  /// An unauthenticated failure.
  const CrateStackUnauthenticated();

  @override
  String toString() => 'CrateStackUnauthenticated';
}

/// A conflict the server decided (`409` without `Retry-After`, e.g. optimistic locking): the
/// person resolves it.
final class CrateStackConflict extends CrateStackFailure {
  /// A conflict.
  const CrateStackConflict({required this.code, required this.message});

  /// The wire code.
  final String code;

  /// The server's message.
  final String message;

  @override
  String toString() => 'CrateStackConflict($code)';
}

/// The request was cancelled because the provider that made it was disposed: never an error a page
/// shows.
final class CrateStackCancelled extends CrateStackFailure {
  /// A cancelled failure.
  const CrateStackCancelled();

  @override
  String toString() => 'CrateStackCancelled';
}

/// A single-row read had no answer from the server and nothing stored: `error.dart` shows it, with
/// a retry.
final class CrateStackNoLocalData extends CrateStackFailure {
  /// Nothing stored under [key].
  const CrateStackNoLocalData(this.key);

  /// The read's key.
  final String key;

  @override
  String toString() => 'CrateStackNoLocalData($key)';
}

/// Reads a client's error into a [CrateStackFailure], or null when it is not one this reader knows.
typedef CrateStackErrorReader = CrateStackFailure? Function(Object error);

/// The readers, in order: the app's reader for its generated `CratestackRpcException` first, then
/// `DioFailures.read`.
///
/// A [CrateStackFailure] passes through as itself; anything unknown is null and is rethrown
/// unchanged by whoever asked.
final class CrateStackErrors {
  /// Errors read by [readers], first answer wins.
  const CrateStackErrors(this.readers);

  /// The readers, in order.
  final List<CrateStackErrorReader> readers;

  /// The failure [error] means, or null.
  CrateStackFailure? classify(Object error) {
    if (error is CrateStackFailure) return error;
    for (final reader in readers) {
      final failure = reader(error);
      if (failure != null) return failure;
    }
    return null;
  }
}

/// The app's readers:
/// `crateStackErrors.overrideWithValue(CrateStackErrors([readGenerated, DioFailures.read]))`.
final crateStackErrors = Provider<CrateStackErrors>(
  (ref) => const CrateStackErrors([]),
);
