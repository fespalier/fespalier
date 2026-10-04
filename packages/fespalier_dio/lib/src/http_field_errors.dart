import 'package:fespalier/fespalier.dart' show FieldErrors;
import 'package:http/http.dart' as http;

import 'problem.dart';

/// Server validation errors as an action's [FieldErrors] (since 0.9.0).
extension FespalierHttpFieldErrors on Future<http.Response> {
  /// Completes with the response, or throws the [FieldErrors] that a validation answer describes:
  /// a response whose status is in [statuses] and whose body [decoder] recognises.
  ///
  /// A response that is not a validation error is returned as it is: it is the caller's to check
  /// (`package:http` does not throw for a status), so this changes only what it throws for a
  /// validation answer. The body is read as UTF-8, which is what JSON is.
  ///
  /// ```dart
  /// final response = await client.put(url, body: body).withFieldErrors();
  /// ```
  ///
  /// See [fieldErrorsOf] for the rules, and `fieldName` for how a server's key becomes a field of
  /// the form's record.
  Future<http.Response> withFieldErrors({
    FieldErrorsDecoder decoder = FieldErrorsDecoders.standard,
    String Function(String key) fieldName = FieldNames.asIs,
    Set<int> statuses = const {400, 422},
  }) async {
    final response = await this;
    final errors = fieldErrorsOf(
      response.statusCode,
      response.bodyBytes,
      decoder: decoder,
      fieldName: fieldName,
      statuses: statuses,
    );
    if (errors != null) throw errors;
    return response;
  }
}
