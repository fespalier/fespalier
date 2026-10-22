/// Dio for fespalier (since 0.9.0): requests cancelled with the provider that made them, server
/// validation errors as an action's `FieldErrors`, writes that are never retried, and (since
/// 0.21.0) Dio on both sides of `package:fespalier_transport`: [DioTransport] sends a transport's
/// requests through your Dio, and [TransportAdapter] lets your Dio send through a transport chain.
///
/// The server's validation-error decoders (`fieldErrorsOf`, `FieldErrorsDecoders`) live in
/// `package:fespalier/problem.dart`; import them from there.
///
/// ```dart
/// final dio = Provider<Dio>((ref) {
///   final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
///   WriteGuard.install(dio); // last: it goes first
///   ref.onDispose(dio.close);
///   return dio;
/// });
/// ```
library;

export 'src/dio_cancel.dart' show FespalierDioRef;
export 'src/dio_errors.dart' show DioErrors;
export 'src/dio_field_errors.dart' show FespalierDioFieldErrors;
export 'src/dio_transport.dart' show DioTransport;
export 'src/transport_adapter.dart' show TransportAdapter;
export 'src/write_guard.dart' show WriteGuard, WriteNotRetried;
