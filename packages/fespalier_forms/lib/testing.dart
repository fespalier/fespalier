/// What tests use from fespalier_forms (since 0.11.0).
library;

import 'dart:async';

import 'package:fespalier/fespalier.dart' show FieldErrors, ProviderContainer;
import 'package:fespalier/persist.dart' show Storage;
import 'package:flutter_test/flutter_test.dart';

import 'src/draft_store.dart';
import 'src/drafts.dart';

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

/// Writes the draft of a form, as the form would, into the `formDraftStorage` of [container]: the
/// way a test starts "the app was closed with this typed in" without typing it.
///
/// [id] is the action's file and name as the generated `useForm` spells them
/// (`(account)/nickname/action.dart#action`), [key] the action's family key (`[7]`; empty for an
/// action with none), [shape] the form's fields and types (`nickname:String,age:int?`) and [fields]
/// what the draft keeps: the raw text of a text field, `DraftCodec.encode`'s JSON for another.
/// Under the container's `formDraftScope`, unless [scope] says another. Does nothing when there is
/// no storage.
FutureOr<void> seedFormDraft(
  ProviderContainer container, {
  required String id,
  List<Object?> key = const [],
  required String shape,
  required Map<String, Object?> fields,
  Duration maxAge = const Duration(days: 7),
  String? scope,
}) {
  final key0 = draftKey(id, key, scope ?? container.read(formDraftScope));
  final storage = container.read(formDraftStorage);
  if (storage is Future<Storage<String, String>?>) {
    return storage.then((s) {
      if (s != null) return saveDraft(s, key0, shape, maxAge, fields);
    });
  }
  if (storage != null) return saveDraft(storage, key0, shape, maxAge, fields);
}

/// The fields of the draft a form kept, as [seedFormDraft] writes them, or null when there is
/// none (or it is expired, or [shape] is not the one it was written for). Reading is what a form
/// does too: an expired draft, or one written for another shape, is deleted as it is read.
FutureOr<Map<String, Object?>?> readFormDraft(
  ProviderContainer container, {
  required String id,
  List<Object?> key = const [],
  required String shape,
  String? scope,
}) {
  final key0 = draftKey(id, key, scope ?? container.read(formDraftScope));
  final storage = container.read(formDraftStorage);
  if (storage is Future<Storage<String, String>?>) {
    return storage.then((s) => s == null ? null : loadDraft(s, key0, shape));
  }
  return storage == null ? null : loadDraft(storage, key0, shape);
}
