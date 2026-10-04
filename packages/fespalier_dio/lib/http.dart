/// `package:http` for fespalier (since 0.9.0): requests aborted with the provider that made them,
/// server validation errors as an action's `FieldErrors`, and writes that `RetryClient` leaves
/// alone.
///
/// A separate library from `package:fespalier_dio/fespalier_dio.dart`, so an app that uses
/// `package:http` links no Dio, and the other way round.
///
/// ```dart
/// final client = ref.abortable(http.Client()); // in a data.dart, before the first await
/// ```
library;

export 'problem.dart';
export 'src/http_abort.dart' show FespalierHttpRef;
export 'src/http_field_errors.dart' show FespalierHttpFieldErrors;
export 'src/write_guard_client.dart' show WriteGuardClient;
