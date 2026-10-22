import 'dart:convert';
import 'dart:typed_data';

import 'package:device/demo/demo_api.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

/// The API the signed-in pages call. In this example it is the in-process server of
/// lib/demo/demo_api.dart; in an app it is yours.
final Uri apiOrigin = Uri.parse(DemoApi.audience);

/// [path] on the API.
Uri api(String path) => apiOrigin.resolve(path);

/// Sends [method] to [path] on the API through [transport] (the app's `authTransport`, which signs
/// it with the device key) and returns the JSON it answers. [attributes] are for the decorators:
/// `DeviceSigner.roleAttribute` asks for the user-present key. Anything but a 2xx is a
/// [ApiError].
Future<Object?> callApi(
  HttpTransport transport,
  String method,
  String path, {
  Object? json,
  Map<String, Object?> attributes = const <String, Object?>{},
}) async {
  final body = json == null ? null : utf8.encode(jsonEncode(json));
  final response = await transport.send(
    TransportRequest(
      method: method,
      uri: api(path),
      headers: {if (body != null) 'content-type': 'application/json'},
      body: body == null ? null : Uint8List.fromList(body),
      attributes: attributes,
    ),
  );
  final text = utf8.decode(await response.bytes());
  if (response.statusCode < 200 || response.statusCode > 299) {
    throw ApiError(response.statusCode, text);
  }
  return text.isEmpty ? null : jsonDecode(text);
}

/// The API answered with a status that is not a success.
class ApiError implements Exception {
  /// An answer of [status] with [body].
  const ApiError(this.status, this.body);

  /// The HTTP status.
  final int status;

  /// What it said.
  final String body;

  @override
  String toString() => 'HTTP $status: $body';
}

/// Who the API says is calling, as `GET /me` answers it.
class Account {
  /// An account on [deviceId] for [phone].
  const Account({
    required this.phone,
    required this.deviceId,
    required this.signedWith,
  });

  /// What `GET /me` answers.
  factory Account.fromJson(Map<String, Object?> json) => Account(
    phone: json['phone']! as String,
    deviceId: json['deviceId']! as String,
    signedWith: json['signedWith']! as String,
  );

  /// The phone number the one-time code went to.
  final String phone;

  /// The id the server gave this device at enrolment.
  final String deviceId;

  /// The key role the request was signed with (`ambient`).
  final String signedWith;
}
