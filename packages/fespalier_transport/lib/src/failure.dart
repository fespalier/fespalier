import 'dart:typed_data';

/// No response came back (since 0.21.0). Sealed: switch on it.
///
/// What the kinds say about the request is what a retrier needs: [TransportUnsent] never
/// left the device, so sending it again is always safe; [TransportUntrusted] never reached a
/// trusted server, so it was not processed either, but the network is not what failed;
/// [TransportTimedOut] and [TransportBroken] may have been run by the server, so only a read may
/// be sent again; [TransportAborted] was stopped on purpose. The text never names the server: the [cause] is the transport's own
/// error, for a log.
sealed class TransportFailure implements Exception {
  /// A failure with the transport's [cause] and the [uri] of the request, when known.
  const TransportFailure(this.cause, [this.uri]);

  /// What the underlying client threw, or null.
  final Object? cause;

  /// The request's URL, when the transport knows it.
  final Uri? uri;

  /// A one-line summary, without the server's name.
  String get summary;

  @override
  String toString() => '$runtimeType: $summary';
}

/// The abort trigger of the request fired before an answer came.
final class TransportAborted extends TransportFailure {
  /// The request was aborted.
  const TransportAborted([super.cause, super.uri]);

  @override
  String get summary => 'the request was aborted';
}

/// The request provably never left: the connection was refused, the host was not found, the
/// connection could not be made in time. Sending it again cannot do anything twice.
final class TransportUnsent extends TransportFailure {
  /// The request never left.
  const TransportUnsent([super.cause, super.uri]);

  @override
  String get summary => 'the request could not be sent';
}

/// The server's TLS certificate was refused (since 0.21.0): the request never reached a trusted
/// server, so it was not processed, but it is not offline either. A certificate that does not
/// verify may be a captive portal or an attack, so a client reads it as unknown, never as being
/// offline: it serves no cached read for it and keeps no queued intent waiting for the network.
/// `DioTransport` throws it for Dio's `badCertificate`, `HttpClientTransport` for a
/// `HandshakeException`, a `TlsException` or a `CertificateException` (not on the web, where the
/// browser tells a refused certificate from nothing else).
final class TransportUntrusted extends TransportFailure {
  /// The certificate was refused.
  const TransportUntrusted([super.cause, super.uri]);

  @override
  String get summary => 'the server\'s certificate was refused';
}

/// The request was sent and no answer came in time: its fate is unknown.
final class TransportTimedOut extends TransportFailure {
  /// No answer came in time.
  const TransportTimedOut([super.cause, super.uri]);

  @override
  String get summary => 'no answer came in time';
}

/// Something other than the API answered: a captive portal's or a gateway's web page where an
/// answer was expected (since 0.21.0). Nobody who knows the API answered, so a client reads it as
/// being offline; the request may have reached the server, so only a read may be sent again.
/// `fespalier_cratestack`'s `PortalTransport` throws it.
final class TransportPortal extends TransportFailure {
  /// A portal answered.
  const TransportPortal([super.cause, super.uri]);

  @override
  String get summary => 'something other than the API answered';
}

/// Anything else that stopped the exchange (a connection that dropped, a malformed answer): its
/// fate is unknown.
final class TransportBroken extends TransportFailure {
  /// The exchange broke.
  const TransportBroken([super.cause, super.uri]);

  @override
  String get summary => 'the exchange failed';
}

/// What `HttpCredentials` throws when it could not be reached (offline while a session renews,
/// a 5xx from the renewal endpoint) (since 0.21.0): nothing was refused, so this says nothing
/// about the session, and the next call asks again. `fespalier_auth`'s `AuthUnavailable`
/// implements it; a transfer reports it as a network failure, not a lost session.
abstract interface class CredentialsUnavailable implements Exception {
  /// What stopped it.
  Object get cause;
}

/// An HTTP error answer (since 0.21.0): the server answered, with a status that is an error. Not
/// a [TransportFailure], because a response did come back; a client that wraps a transport's
/// answers in exceptions (Dio does for a 4xx or a 5xx) can carry one through
/// `DioErrors.toTransport`, so a reader that knows no Dio type can classify it.
///
/// `toString` shows the status only: the body may hold personal data.
final class TransportStatusError implements Exception {
  /// An answer with [statusCode], [headers] (lower-case names) and the [body] bytes.
  const TransportStatusError({
    required this.statusCode,
    required this.headers,
    required this.body,
    this.reasonPhrase,
  });

  /// The HTTP status code.
  final int statusCode;

  /// The headers, with lower-case names.
  final Map<String, String> headers;

  /// The whole body.
  final Uint8List body;

  /// The reason phrase, when there is one.
  final String? reasonPhrase;

  @override
  String toString() => 'TransportStatusError: HTTP $statusCode';
}
