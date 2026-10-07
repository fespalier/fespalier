/// Dio for fespalier_cratestack (since 0.10.0): requests of a generated client cancelled with the
/// provider that made them, and a `DioException` read as a `CrateStackFailure`.
///
/// A separate library from `package:fespalier_cratestack/fespalier_cratestack.dart`, so an app
/// whose generated client does not use Dio links none.
///
/// ```dart
/// final dio = Provider<Dio>((ref) {
///   final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
///     ..interceptors.add(const CrateStackCancelInterceptor());
///   WriteGuard.install(dio); // last: it goes first
///   ref.onDispose(dio.close);
///   return dio;
/// });
/// ```
library;

export 'src/dio/cancel.dart'
    show CrateStackCancelInterceptor, CrateStackCancelRef;
export 'src/dio/failures.dart' show DioFailures;
