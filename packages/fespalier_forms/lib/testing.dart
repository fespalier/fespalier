/// What tests use from fespalier_forms (since 0.11.0).
library;

import 'package:fespalier/fespalier.dart' show FieldErrors;
import 'package:flutter_test/flutter_test.dart';

/// Matches a [FieldErrors] with exactly these [fields] (by field name) and, when given, this
/// [message].
///
/// ```dart
/// await expectLater(
///   run(input), // an action's Future, or ActionHandle.call
///   throwsA(isFieldErrors({'nickname': 'Enter a nickname'})),
/// );
/// ```
Matcher isFieldErrors(Map<String, String> fields, {String? message}) =>
    isA<FieldErrors>()
        .having((e) => e.fields, 'fields', fields)
        .having((e) => e.message, 'message', message);
