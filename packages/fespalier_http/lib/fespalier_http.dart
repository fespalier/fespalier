/// `package:http` for fespalier (since 0.15.0; it was `package:fespalier_dio/http.dart` from
/// 0.9.0 to 0.14.0): requests aborted with the provider that made them, server validation errors
/// as an action's `FieldErrors`, an `http.Client` as an `HttpTransport` and back.
///
/// `HttpClientTransport` sends a `fespalier_transport` request through any `http.Client`, and
/// `TransportClient` lets code written for `package:http` (`RetryClient`, `ref.abortable(client)`)
/// send through a transport chain (a session, a write guard). An app that uses `package:http`
/// links no Dio.
///
/// ```dart
/// final client = ref.abortable(http.Client()); // in a data.dart, before the first await
/// ```
library;

export 'src/abort.dart' show FespalierHttpRef;
export 'src/field_errors.dart' show FespalierHttpFieldErrors;
export 'src/http_client_transport.dart' show HttpClientTransport;
export 'src/transport_client.dart' show TransportClient;
