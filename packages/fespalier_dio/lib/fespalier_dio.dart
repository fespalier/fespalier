/// Dio for fespalier (since 0.9.0): requests cancelled with the provider that made them, server
/// validation errors as an action's `FieldErrors`, and writes that are never retried.
///
/// A separate library from `package:fespalier_http/fespalier_http.dart`, so an app that uses `package:http`
/// links no Dio, and the other way round.
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

export 'package:fespalier_http/problem.dart';
export 'src/dio_cancel.dart' show FespalierDioRef;
export 'src/dio_field_errors.dart' show FespalierDioFieldErrors;
export 'src/write_guard.dart' show WriteGuard, WriteNotRetried;
