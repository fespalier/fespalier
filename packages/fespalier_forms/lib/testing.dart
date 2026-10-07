/// What tests use from fespalier_forms (since 0.11.0).
library;

import 'dart:async';

import 'package:fespalier/fespalier.dart'
    show FieldErrors, ProviderContainer, TypedLocation;
import 'package:fespalier/testing.dart' show Override, currentLocation;
import 'package:fespalier/persist.dart' show Storage;
import 'package:flutter_test/flutter_test.dart';

import 'src/draft_store.dart';
import 'src/drafts.dart';
import 'src/leave.dart';

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
///
/// For the draft of a multi-page form, [steps] are the steps it had done (since 0.11.0):
/// `steps: {SignupStep.name}`.
FutureOr<void> seedFormDraft(
  ProviderContainer container, {
  required String id,
  List<Object?> key = const [],
  required String shape,
  required Map<String, Object?> fields,
  Set<Enum> steps = const {},
  Duration maxAge = const Duration(days: 7),
  String? scope,
}) {
  final key0 = draftKey(id, key, scope ?? container.read(formDraftScope));
  final storage = container.read(formDraftStorage);
  final done = steps.isEmpty ? null : [for (final s in steps) s.name];
  if (storage is Future<Storage<String, String>?>) {
    return storage.then((s) {
      if (s != null) {
        return saveDraft(s, key0, shape, maxAge, fields, steps: done);
      }
    });
  }
  if (storage != null) {
    return saveDraft(storage, key0, shape, maxAge, fields, steps: done);
  }
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

/// The names of the steps the draft of a multi-page form has done (since 0.11.0), as
/// [seedFormDraft]'s `steps` writes them; null when there is no draft, an empty list when it holds
/// none.
FutureOr<List<String>?> readFormDraftSteps(
  ProviderContainer container, {
  required String id,
  List<Object?> key = const [],
  required String shape,
  String? scope,
}) {
  final key0 = draftKey(id, key, scope ?? container.read(formDraftScope));
  final storage = container.read(formDraftStorage);
  List<String>? steps(DraftEntry? entry) => entry?.steps;
  if (storage is Future<Storage<String, String>?>) {
    return storage.then((s) async {
      if (s == null) return null;
      return steps(await loadDraftEntry(s, key0, shape));
    });
  }
  if (storage == null) return null;
  final loaded = loadDraftEntry(storage, key0, shape);
  return loaded is Future<DraftEntry?> ? loaded.then(steps) : steps(loaded);
}

/// Expects the router to be at [step] of a multi-page form (since 0.11.0): the last segment of the
/// current location is the step's name (`contact_info` and `contact-info` are `contactInfo`). Give
/// the step's typed [route] to compare the whole location instead:
///
/// ```dart
/// expectStep(tester, SignupStep.contact);
/// expectStep(tester, SignupStep.contact, route: const SignupContactRoute());
/// ```
void expectStep(WidgetTester tester, Enum step, {TypedLocation? route}) {
  final location = currentLocation(tester);
  final path = Uri.parse(location).path;
  if (route != null) {
    expect(
      path,
      Uri.parse(route.location).path,
      reason: 'the router is at $location, not at step ${step.name}',
    );
    return;
  }
  String plain(String s) => s.replaceAll(RegExp('[-_]'), '').toLowerCase();
  final last = Uri.parse(location).pathSegments.where((s) => s.isNotEmpty);
  expect(
    plain(last.isEmpty ? '' : last.last),
    plain(step.name),
    reason: 'the router is at $location, not at step ${step.name}',
  );
}

/// Answers the question a `leave.dart` puts about unsaved changes, for a test (since 0.11.0).
///
/// ```dart
/// await pumpRouter(
///   tester,
///   AppRoutes.router(initialLocation: '/nickname'),
///   overrides: [LeavePrompts.answer(LeaveChoice.discard)],
/// );
/// ```
abstract final class LeavePrompts {
  /// A `leavePrompt` override that answers [choice] at once, without opening a sheet.
  static Override answer(LeaveChoice choice) =>
      leavePrompt.overrideWithValue((context, page) => choice);
}
