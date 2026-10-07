import 'package:fespalier/fespalier.dart' show FieldErrors, Ref;

import 'errors.dart';

/// The code and status of CrateStack's validation refusal.
const _validationStatus = 422;
const _validationCode = 'VALIDATION_ERROR';

/// The documented message of a rejected field: `field 'email' is not a valid email address`.
final _fieldMessage = RegExp(r"^\s*field '([^']+)'");

/// Reading a validation refusal as [FieldErrors].
extension CrateStackFieldErrorsOf on CrateStackErrors {
  /// The fields of a `422` `VALIDATION_ERROR` as fespalier's [FieldErrors], or null when [error] is
  /// anything else. The rules, in order:
  ///
  /// 1. The status is `422` and the code is `VALIDATION_ERROR`.
  /// 2. A message starting `idempotency_key_conflict` is never a field error: it is a bug in the
  ///    caller (the stored body changed), so it is null and the failure is rethrown.
  /// 3. `details` that is a map of field to message, or a list of `{field|path, message}`, maps
  ///    field by field. That shape is an assumption (CrateStack documents none): anything else is
  ///    ignored, not an error.
  /// 4. Otherwise the documented `field '<name>' ...` message becomes `FieldErrors({name: message})`.
  /// 5. Otherwise `FieldErrors({}, message: message)`.
  ///
  /// [fieldName] turns the server's key into the name of the field of the form's record.
  FieldErrors? fieldErrorsOf(
    Object error, {
    String Function(String key)? fieldName,
  }) {
    final failure = classify(error);
    if (failure is! CrateStackRefused ||
        failure.status != _validationStatus ||
        failure.code != _validationCode) {
      return null;
    }
    if (failure.message.startsWith('idempotency_key_conflict')) return null;
    String name(String key) => fieldName == null ? key : fieldName(key);

    final fromDetails = _fromDetails(failure.details, name);
    if (fromDetails != null) return fromDetails;

    final fromMessage = <String, String>{};
    for (final part in failure.message.split(RegExp(r'[;\n]'))) {
      final match = _fieldMessage.firstMatch(part);
      if (match != null) fromMessage[name(match.group(1)!)] = part.trim();
    }
    if (fromMessage.isNotEmpty) return FieldErrors(fromMessage);
    return FieldErrors(const {}, message: failure.message);
  }
}

FieldErrors? _fromDetails(Object? details, String Function(String) name) {
  final fields = <String, String>{};
  if (details is Map<Object?, Object?>) {
    for (final entry in details.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String) return null;
      if (value is String) {
        fields[name(key)] = value;
      } else if (value is List<Object?> && value.every((v) => v is String)) {
        fields[name(key)] = value.join(', ');
      } else {
        return null;
      }
    }
  } else if (details is List<Object?>) {
    for (final item in details) {
      if (item is! Map<Object?, Object?>) return null;
      final key = item['field'] ?? item['path'];
      final message = item['message'];
      if (key is! String || message is! String) return null;
      fields[name(key)] = message;
    }
  } else {
    return null;
  }
  return fields.isEmpty ? null : FieldErrors(fields);
}

/// On an action's own `Future` (like fespalier_dio's `withFieldErrors`): a `422`
/// `VALIDATION_ERROR` becomes [FieldErrors].
extension CrateStackFieldErrors<T> on Future<T> {
  /// Completes like this future, except that a validation refusal (see
  /// `CrateStackErrors.fieldErrorsOf` for the rules) is thrown as [FieldErrors], so the form shows
  /// each message under its field. Anything else is rethrown as the very same object.
  ///
  /// It reads the errors with the app's [crateStackErrors] through [ref].
  Future<T> withCrateStackFieldErrors(
    Ref ref, {
    String Function(String key)? fieldName,
  }) async {
    try {
      return await this;
    } on Object catch (error, stackTrace) {
      final errors = ref
          .read(crateStackErrors)
          .fieldErrorsOf(error, fieldName: fieldName);
      if (errors == null) rethrow;
      Error.throwWithStackTrace(errors, stackTrace);
    }
  }
}
