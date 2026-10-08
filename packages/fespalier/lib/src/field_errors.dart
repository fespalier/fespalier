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

/// An error the server decided, which a page never hides behind data it kept (since 0.13.1).
///
/// A route whose `data.dart` has a `freshness` or a `dataCache` keeps its page on the value it
/// had when a reload fails (`DataView.keepDataOnError`): right for a lost connection or a 5xx,
/// wrong for an answer. A refusal (a `403`, a failed authorization) means the person may no
/// longer see what is on screen, so a failure that implements this goes to `error.dart` even
/// when there is a value. Implement it on the error a data function throws; core knows no
/// client, so `fespalier_cratestack` marks `CrateStackRefused` and `fespalier_auth` marks
/// `AuthRejected`. A plain error stays kept. Checking it never makes a `Future`.
abstract interface class DataRefusal {}
