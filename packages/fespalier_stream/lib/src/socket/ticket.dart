import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier/fespalier.dart' show DataRefusal;
import 'package:fespalier_transport/fespalier_transport.dart';

import 'grant.dart';

/// The server refused a WebSocket ticket (since 0.25.0): its ticket endpoint answered a 4xx other
/// than 408 and 429 (after a session's renewal and resend, for a 401). The connection that asked
/// ends for good.
///
/// It is a [DataRefusal], so a page that keeps its value on an error shows `error.dart` instead.
/// `toString` shows the status only.
final class SocketTicketRefused implements Exception, DataRefusal {
  /// A refusal with [statusCode].
  const SocketTicketRefused(this.statusCode);

  /// The HTTP status code.
  final int statusCode;

  @override
  String toString() => 'SocketTicketRefused: HTTP $statusCode';
}

/// A [SocketGrantor] that asks [ticketEndpoint] for a single-use ticket through [transport] and
/// puts it in the socket URL's query, under [param] (since 0.25.0).
///
/// ```dart
/// SocketConnection(
///   const WebSocketConnector(),
///   Uri.parse('wss://api.example.com/chat'),
///   grantor: ticketGrantor(ref.watch(apiTransport), Uri.parse('https://api.example.com/ws-ticket')),
/// )
/// ```
///
/// A browser cannot set a header on a WebSocket handshake, so the credential the app's session
/// holds cannot go with it. The ticket is the usual way across: a `POST` through the app's
/// transport chain (so its session, signature and trace apply, and a 401 renews and is sent
/// again), answered with a short-lived ticket the server accepts once, in the socket's URL. It is
/// asked for again before every connect.
///
/// The answer is `application/json` with the ticket in [field] (`{"ticket": "..."}`), or
/// `text/plain` with the ticket as the body, at most 16 KiB. A 4xx other than 408 and 429 throws
/// [SocketTicketRefused] (the connection ends); a 408, 429 or 5xx a `TransportStatusError` with an
/// empty body (the connection waits, `unavailable`); another answer (a captive portal's page, an
/// empty ticket, a body over 16 KiB) a `FormatException` with no text of the answer (the
/// connection waits, `failed`). The body of an answer that is not a 2xx is never read: the request
/// is aborted, so a large error page costs nothing. [headers] are added to the request's, a name
/// compared without regard to case (yours replace `Accept`, never sit beside it).
///
/// The `POST` is a write (no `Idempotency-Key`): a `WriteGuardTransport` keeps a retrier from
/// sending it again after a failure whose outcome is unknown, which is right for a ticket the
/// server may already have minted. Nothing is lost: the next connect asks for a new one. A
/// session still renews and resends after a 401, which the server did not process.
///
/// The ticket is in the URL, so a server's access log can keep it: make it single-use and short
/// lived. fespalier never records it (a `SocketGrant`'s `toString` prints no field, and telemetry
/// reports no URL).
SocketGrantor ticketGrantor(
  HttpTransport transport,
  Uri ticketEndpoint, {
  String param = 'ticket',
  String field = 'ticket',
  Map<String, String> headers = const <String, String>{},
}) => (url) async {
  // Completed to give the answer up without reading it (or what is left of it).
  final giveUp = Completer<void>();
  final response = await transport.send(
    TransportRequest(
      method: 'POST',
      uri: ticketEndpoint,
      headers: mergeHeaders(<String, String>{
        'Accept': 'application/json, text/plain',
      }, headers),
      body: Uint8List(0),
      // The connection's attempt: given up, the request is aborted. So is an answer not read.
      abortTrigger: TransportZone.merge(TransportZone.current(), giveUp.future),
      attributes: <String, Object?>{TransportMemo.key: TransportMemo()},
    ),
  );
  final status = response.statusCode;
  if (status < 200 || status >= 300) {
    // Nothing of an answer that is no ticket is read: the request is aborted, so neither a large
    // page nor a slow one is waited for.
    _letGo(giveUp);
    if (status == 408 || status == 429 || status >= 500) {
      throw TransportStatusError(
        statusCode: status,
        headers: response.headers,
        body: Uint8List(0),
        reasonPhrase: response.reasonPhrase,
      );
    }
    if (status >= 400) throw SocketTicketRefused(status);
    throw const FormatException('ticketGrantor: the answer is not a ticket');
  }
  final body = await _readCapped(response, giveUp);
  if (body == null) {
    throw const FormatException('ticketGrantor: the answer is not a ticket');
  }
  final ticket = _ticketOf(response.headers['content-type'], body, field);
  if (ticket == null || ticket.isEmpty) {
    throw const FormatException('ticketGrantor: the answer is not a ticket');
  }
  return SocketGrant(
    url.replace(
      queryParameters: <String, Object>{
        ...url.queryParametersAll,
        param: <String>[ticket],
      },
    ),
  );
};

/// The most a ticket answer may weigh: a ticket is a few hundred bytes.
const int _maxTicketBytes = 16 * 1024;

/// Aborts the request behind an answer that is not read, as `EventSource` gives up an answer it
/// does not read: cancelling a body is not enough to close a connection with every client.
void _letGo(Completer<void> giveUp) {
  if (!giveUp.isCompleted) giveUp.complete();
}

/// The body of [response], or null when it is longer than [_maxTicketBytes] (the rest is not
/// read: the request is aborted).
Future<Uint8List?> _readCapped(
  TransportResponse response,
  Completer<void> giveUp,
) async {
  final builder = BytesBuilder(copy: false);
  final iterator = StreamIterator<List<int>>(response.body);
  try {
    while (await iterator.moveNext()) {
      builder.add(iterator.current);
      if (builder.length > _maxTicketBytes) {
        if (!giveUp.isCompleted) giveUp.complete();
        return null;
      }
    }
  } finally {
    unawaited(
      iterator.cancel().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  }
  return builder.takeBytes();
}

String? _ticketOf(String? contentType, Uint8List body, String field) {
  final type = contentType?.split(';').first.trim().toLowerCase() ?? '';
  try {
    if (type == 'application/json' || type.endsWith('+json')) {
      final value = jsonDecode(utf8.decode(body));
      return value is Map<String, Object?> && value[field] is String
          ? value[field]! as String
          : null;
    }
    if (type == 'text/plain') return utf8.decode(body).trim();
  } on FormatException {
    return null;
  }
  return null;
}
