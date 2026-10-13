import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart' show FieldErrors;

import 'package:fespalier_http/problem.dart';

/// Server validation errors as an action's [FieldErrors] (since 0.9.0).
extension FespalierDioFieldErrors<T> on Future<T> {
  /// Completes like this future, except that a [DioException] whose response has a status in
  /// [statuses] and a body [decoder] recognises is thrown as those [FieldErrors], so the form
  /// (see https://github.com/fespalier/fespalier/blob/main/docs/forms.md, `fespalier_forms`) shows
  /// each message under its field. Any other error is rethrown as it was: the very same object.
  ///
  /// It is not an interceptor on purpose: an interceptor can only reject with a `DioException`, and
  /// a form reads a [FieldErrors]. Use it in an `action.dart` (a `data.dart` that gets a 422 wants
  /// its `error.dart`):
  ///
  /// ```dart
  /// await ref.read(dio).put<Object?>('/me', data: body).withFieldErrors();
  /// ```
  ///
  /// [fieldName] turns the server's key into the name of the field of the form's record
  /// ([FieldNames.camelCase] for names that differ only in case); a key that is no field shows in
  /// the form's `error`. See [fieldErrorsOf] for the rules.
  Future<T> withFieldErrors({
    FieldErrorsDecoder decoder = FieldErrorsDecoders.standard,
    String Function(String key) fieldName = FieldNames.asIs,
    Set<int> statuses = const {400, 422},
  }) async {
    try {
      return await this;
    } on DioException catch (error, stackTrace) {
      final response = error.response;
      final errors = fieldErrorsOf(
        response?.statusCode,
        response?.data,
        decoder: decoder,
        fieldName: fieldName,
        statuses: statuses,
      );
      if (errors == null) rethrow;
      Error.throwWithStackTrace(errors, stackTrace);
    }
  }
}
