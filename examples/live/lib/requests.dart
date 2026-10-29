import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier_transport/fespalier_transport.dart';

/// `GET` [url] through [transport] and decode its JSON; a status other than 200 is a
/// [TransportStatusError].
Future<Object?> getJson(HttpTransport transport, Uri url) async {
  final response = await transport.send(
    TransportRequest(
      method: 'GET',
      uri: url,
      headers: const {'accept': 'application/json'},
    ),
  );
  final bytes = await response.bytes();
  if (response.statusCode != 200) {
    throw TransportStatusError(
      statusCode: response.statusCode,
      headers: response.headers,
      body: bytes,
      reasonPhrase: response.reasonPhrase,
    );
  }
  return jsonDecode(utf8.decode(bytes));
}

/// `POST` [url] with no body through [transport]: one of the demo's server controls (advance an order,
/// drop a stream, refuse tickets). A status that is not a 2xx is a [TransportStatusError].
Future<void> post(HttpTransport transport, Uri url) async {
  final response = await transport.send(
    TransportRequest(method: 'POST', uri: url, body: Uint8List(0)),
  );
  final bytes = await response.bytes();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw TransportStatusError(
      statusCode: response.statusCode,
      headers: response.headers,
      body: bytes,
      reasonPhrase: response.reasonPhrase,
    );
  }
}
