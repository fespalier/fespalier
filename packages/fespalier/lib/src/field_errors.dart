/// What an action, or the `validate()` beside it, throws to say which fields of its input are
/// wrong (since 0.8.1). A form shows each message under its field, and [message] above them.
///
/// The keys are the names of the input's fields (`amount` for `({int amount, String note})`).
final class FieldErrors implements Exception {
  /// The messages of [fields] by field name, and [message] for the input as a whole.
  const FieldErrors(this.fields, {this.message});

  /// A message per field, by the field's name.
  final Map<String, String> fields;

  /// What is wrong with the input as a whole, if anything.
  final String? message;

  /// Whether it says nothing is wrong: what `validate()` returns for a valid input, like null.
  bool get isEmpty => fields.isEmpty && message == null;

  @override
  String toString() => [
    ?message,
    for (final e in fields.entries) '${e.key}: ${e.value}',
  ].join('; ');
}
