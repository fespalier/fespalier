/// The seam fespalier's networking packages share (since 0.21.0): an [HttpTransport] interface
/// with its request and response, the session credentials contract and the one write rule.
/// Pure Dart, no dependencies: `package:fespalier_http` implements it over `package:http`,
/// `package:fespalier_dio` over Dio, and an app's own client can.
///
/// ```dart
/// final transport = SessionTransport(
///   WriteGuardTransport(HttpClientTransport(http.Client())),
///   ref.watch(authorizer),
/// );
/// final response = await transport.send(
///   TransportRequest(method: 'GET', uri: Uri.parse('https://api.example.com/orders')),
/// );
/// ```
library;

export 'src/credentials.dart'
    show
        AuthorizedTransportRequest,
        HttpAuthorization,
        HttpCredentials,
        transportReplayKey;
export 'src/failure.dart';
export 'src/memo.dart';
export 'src/request.dart';
export 'src/response.dart';
export 'src/transport.dart';
export 'src/write_guard.dart';
export 'src/writes.dart';
export 'src/zone.dart';
