/// `package:http` for fespalier (since 0.15.0; it was `package:fespalier_dio/http.dart` from
/// 0.9.0 to 0.14.0): requests aborted with the provider that made them, server validation errors
/// as an action's `FieldErrors`, and writes that `RetryClient` leaves alone.
///
/// Any `http.Client` fits: the seam is `package:http`'s own `Client`, `BaseRequest` and
/// `StreamedResponse`. An app that uses `package:http` links no Dio.
///
/// ```dart
/// final client = ref.abortable(http.Client()); // in a data.dart, before the first await
/// ```
library;

export 'problem.dart';
export 'src/abort.dart' show FespalierHttpRef;
export 'src/field_errors.dart' show FespalierHttpFieldErrors;
export 'src/write_guard_client.dart' show WriteGuardClient;
export 'src/writes.dart' show HttpWrites;
