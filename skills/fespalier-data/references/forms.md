# Forms: `fespalier_forms` (since 0.11.0)

The form of an `action.dart` is the `fespalier_forms` package. Until 0.10.0 it was part of
`fespalier`; an app on 0.10.0 or earlier imports nothing for it and has no `fespalier_forms` in its
pubspec (see `fespalier-migration`, "0.10 to 0.11"). Runtime:
`packages/fespalier_forms/lib/src/action_form.dart`; the names the generator reads are in
`cli/src/forms.rs`, and the dependency check is `check_dependency` there.

There is **no `form.dart`**: `form()` is a _companion function_ in the `action.dart` of the action
it belongs to, found by name beside `validate()` and `optimistic()`
([`optimistic.md`](optimistic.md)). For the action called `action` it is `form`; for `approve` it is
`approveForm`, and the hook is `useApproveForm`. A companion is **never an action**, even when it
takes a `Ref` (that is an error).

## Install

Add `fespalier_forms` under `dependencies:`, **at the same git `url` and `ref` as `fespalier`**
(pub resolves the two to one package only then; the block to copy is
`packages/fespalier_forms/README.md`), and run `fsp gen`:

- `app.g.dart` imports `package:fespalier_forms/fespalier_forms.dart` **only when some `action.dart`
  has a `form()`**. An app with no form imports nothing and pays nothing.
- With a `form()` and no `fespalier_forms` under `dependencies:`, `fsp` reports an error at the
  `form()` (the message is in `fespalier-troubleshooting`, `diagnostics-data-and-hooks.md`). The
  output depends on the pubspec alone, never on `pub get`.
- A page that only calls `XRoute.useForm(...)` needs no import (the types are inferred). Code that
  names `ActionForm`, `ActionField`, `ActionTextField`, `ActionFormFields`, `FieldCodec`,
  `ActionFormMessages`, `ActionFormValidation` or `useActionForm` imports
  `package:fespalier_forms/fespalier_forms.dart`; `package:fespalier` no longer exports them.
- **`FieldErrors`, `validate()` and `optimistic()` stay in `fespalier`.** They are the error contract
  of actions and work without a form.
- `package:fespalier_forms/testing.dart` has `isFieldErrors(fields, message:)`, a matcher for the
  `FieldErrors` an action throws.

The samples share a tiny backend. The server spells the nickname its own way (trimmed, lower
case), which is what shows that the page ends on the server's value, not the guess.

```dart
// lib/profile.dart
import 'dart:async';

import 'package:fespalier/fespalier.dart';

class Profile {
  const Profile(this.nickname, this.newsletter);

  final String nickname;
  final bool newsletter;
}

class ProfileApi {
  Profile _profile = const Profile('Ann', false);

  /// A save waits for this when it is set: how a test holds a write pending.
  Completer<void>? gate;

  Future<Profile> load() async => _profile;

  Future<Profile> save({required String nickname, required bool newsletter}) async {
    await gate?.future;
    final spelled = nickname.trim().toLowerCase();
    if (spelled == 'admin') {
      throw const FieldErrors({'nickname': 'That nickname is taken'});
    }
    return _profile = Profile(spelled, newsletter);
  }
}

final profileApiProvider = Provider<ProfileApi>((ref) => ProfileApi());
```

```dart
// lib/app/nickname/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/profile.dart';

Future<Profile> data(Ref ref) => ref.read(profileApiProvider).load();
```

```dart
// lib/app/nickname/action.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/profile.dart';

/// The input of the action, and so the fields of its form: a record with named fields.
typedef NicknameFields = ({String nickname, bool newsletter});

/// The form starts from the data the page passes to `useForm(data:)`.
NicknameFields form(Profile profile) =>
    (nickname: profile.nickname, newsletter: profile.newsletter);

/// Checked on the device before the action runs, and live in the form after a first submit.
FieldErrors? validate(NicknameFields input) => FieldErrors({
  if (input.nickname.trim().isEmpty) 'nickname': 'Enter a nickname',
});

/// What the page shows of its data.dart while the save is in flight.
Profile optimistic(Profile current, NicknameFields input) =>
    Profile(input.nickname, input.newsletter);

/// The server has the last word: a taken nickname comes back as a field error.
Future<Profile> action(Ref ref, {required NicknameFields input}) => ref
    .read(profileApiProvider)
    .save(nickname: input.nickname, newsletter: input.newsletter);
```

```dart
// lib/app/nickname/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/profile.dart';

/// A HookConsumerWidget: `useForm` is a real hook.
class NicknamePage extends HookConsumerWidget {
  const NicknamePage({super.key, required this.profile});

  /// data.dart's, by type: with the optimistic patch while a save is in flight.
  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = NicknameRoute.useForm(ref, data: profile);
    final f = form.fields;
    return Scaffold(
      body: Column(
        children: [
          Text('Hello ${profile.nickname}'),
          TextField(
            controller: f.nickname.controller,
            decoration: InputDecoration(errorText: f.nickname.error),
          ),
          CheckboxListTile(
            title: const Text('Newsletter'),
            value: f.newsletter.value,
            onChanged: f.newsletter.didChange,
          ),
          if (form.error case final e?) Text('$e'),
          FilledButton(
            onPressed: form.onSubmit, // null while the action runs: disabled
            child: Text(form.isPending ? 'Saving...' : 'Save'),
          ),
          TextButton(
            onPressed: form.isDirty ? form.reset : null,
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }
}
```

```dart
// test/nickname_test.dart
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_forms/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/profile.dart';

void main() {
  testWidgets('the title shows the typed nickname at once, then the server\'s', (
    tester,
  ) async {
    final api = ProfileApi()..gate = Completer<void>();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/nickname'),
      overrides: [profileApiProvider.overrideWithValue(api)],
    );
    expect(find.text('Hello Ann'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Bob');
    await tester.tap(find.text('Save'));
    await tester.pump();
    // Pending: the optimistic title, and a disabled button.
    expect(find.text('Hello Bob'), findsOneWidget);
    expect(find.text('Saving...'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    api.gate!.complete();
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      // Never the old value in between.
      expect(find.text('Hello Ann'), findsNothing);
    }
    // The server's spelling replaced the guess.
    expect(find.text('Hello bob'), findsOneWidget);
  });

  testWidgets('a taken nickname lands under its field', (tester) async {
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/nickname'),
      overrides: [profileApiProvider.overrideWithValue(ProfileApi())],
    );
    await tester.enterText(find.byType(TextField), 'admin');
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump();
    expect(find.text('That nickname is taken'), findsOneWidget);
    expect(find.text('Hello Ann'), findsOneWidget);
  });

  test('validate() refuses an empty nickname before the write starts', () {
    final container = ProviderContainer(
      overrides: [profileApiProvider.overrideWithValue(ProfileApi())],
    );
    addTearDown(container.dispose);
    expect(
      () => container
          .read(NicknameRoute.action.notifier)
          .call((nickname: ' ', newsletter: false)),
      throwsA(isFieldErrors({'nickname': 'Enter a nickname'})),
    );
  });
}
```

## `form()`: typed fields from a record

- **The input must be a record type with named fields**, spelled inline (`required ({int amount,
String note}) input`) or as a `typedef` **declared in the same `action.dart`**: `fsp` reads the
  field names and types from this file and from no other, so a typedef imported from elsewhere,
  a class or `(int, String)` is an error (F4a, F4b below).
- **`form()` returns the input's type as written** (the same text: `NicknameFields`, not the
  record spelled out when the input is the typedef) and takes **no `Ref`**. It takes nothing, or
  one positional, required, **typed** parameter: the value the form starts from.
- **`useForm`** (`useApproveForm` for `approve`) is generated on the route class or the section
  handle. It takes the action's keys, `data:` (only when `form()` takes a parameter; then required,
  typed as that parameter) and `validation:`, `resetOnSuccess:`, `messages:`, `draft:` (since
  0.11.0, see "Drafts" below). **`data:` is what the page got**: pass the page's own `profile`,
  which is the data with the optimistic patch while a write is in flight. A key of the action
  named `data`, `validation`, `resetOnSuccess`, `messages` or `draft` is an error.
- **A real hook.** Call it in a `HookConsumerWidget`'s `build`; outside a `HookWidget`
  `flutter_hooks` asserts. (`useAction` only needs a `WidgetRef`.) A different action key (another
  `id`) is a new form.
- **Field kinds**, chosen from the record field's type text: `String`, `String?`, `int`,
  `int?`, `double`, `double?`, `num`, `num?` are text fields (`form.fields.x.controller`, owned and
  disposed by the form); anything else (`bool`, an enum, a `DateTime`, a list) is a value field
  (`value`, `didChange`). Empty text is `null` for a nullable field and `Required` for a
  non-nullable number; bad numbers read `Enter a whole number` or `Enter a number`. Translate with
  `messages: ActionFormMessages(required: ..., integer: ..., number: ...)`.
- **Submit** (`form.onSubmit`, null while pending; `form.submit()` returns the result or null): a
  field that doesn't parse, or a non-empty `validate()`, stops it and the action is **not
  called**. A sync action stays sync (`submit()` returns a value, not a `Future`).
- **Errors per field**, in this order: the field's parse error, the `FieldErrors` the action
  threw for that name (cleared when that field is edited), `validate()`'s. Nothing shows before the
  first submit (`ActionFormValidation.afterSubmit`, the default); `onChange` shows a field once it
  is changed. **`form.error`** is the rest: `FieldErrors.message`, the messages of keys that are
  no field (a typo in `FieldErrors({'nickame': ...})` shows here, never lost), or a non-field
  failure.
- **New data.** The page gets a new data object after the action's invalidation (or a refresh):
  the fields the user has **not** changed follow it, the changed ones keep what was typed. While the
  form's own action is running the data is not read again. After a success the fields become the
  new baseline (`isDirty` false). `reset()` goes back to the last data and idles the action;
  `resetOnSuccess: true` restarts every field from `form(data)` after a success.
- **Not built** (0.11.0): async per-field validators, a control tree, custom text codecs for dates and
  enums (use a picker and a value field), an `fsp new --form` scaffold.

## Drafts: what the user typed, kept per route (since 0.11.0)

`NicknameRoute.useForm(ref, data: p, draft: const FormDraft())` keeps what the user changed and
puts it back when the route is opened again. **Opt-in for each form, never a default**: list
what must not reach the disk in `FormDraft(exclude: {'password'})` (`maxAge` is 7 days).

- **Storage and key.** `formDraftStorage` (a `FutureOr<Storage<String, String>?>` provider that
  defaults to `dataCacheStorage`; null keeps nothing) under
  `fespalier_forms.draft:<action file>#<action>:<family key as JSON>[:<formDraftScope>]`. Two
  `/orders/:id/edit` pages have two drafts. Give `formDraftScope` (a `String?` provider) the
  account id, and call `clearFormDrafts(ref)` (`clearFormDraftsOf(ref)` from a provider) at
  sign-out: it deletes every draft through the index `fespalier_forms.drafts`.
- **Kept**: only the fields that changed. A text field keeps its raw text (`abc` in an `int?`
  field survives); a `bool`, `DateTime` or enum value field is kept through the `DraftCodec` the
  generator picks (`boolean`, `optionalBoolean`, `dateTime`, `optionalDateTime`, `enumOf`,
  `optionalEnumOf`); any other type is not drafted.
- **Written** when the form is disposed with changes and when the app is `hidden`, `paused` or
  `detached` (an `AppLifecycleListener` the hook owns and disposes); never per keystroke, no timer.
  **Restored** when the form starts: before the first build for a storage whose `read` is sync,
  when it answers otherwise, and then only into fields the user has not touched and not while the
  action runs. **Deleted** by a successful submit, `reset()` and `clearFormDrafts`, and when it is
  expired or was written for another `shape` (the generated `nickname:String,age:int?,...`: change
  a field and the old drafts go).
- A draft is read once at start; storage failures are printed in debug and never reach the page; a
  budgeted storage (`fespalier_storage`) may evict a draft.
- **Tests**: share a `MemoryDataStorage`, or `seedFormDraft(container, id:, key:, shape:, fields:)`
  and `readFormDraft(...)` from `package:fespalier_forms/testing.dart` (the `id` and `shape` are the
  strings in `app.g.dart`); `handleAppLifecycleStateChanged(AppLifecycleState.paused)` writes a
  draft, and `resumed` must follow before the next `pump`.

## Testing a form

Hold the save on a `Completer` and `pump()`; no timer, no `runAsync` (the `// test/` sample above).
`enterText` on the `TextField` types into the field's controller; `onSubmit` is the button's
`onPressed`, `null` while pending. For a section, `TeamsTeamIdSection.addMember(ref, ...)` from the
page's element (`tester.element(find.byType(MembersPage)) as WidgetRef`), then pump in steps and
assert the list never loses the new member.

- **The package starts no timer, no microtask and reads no clock** (`test/no_timers_test.dart`
  greps `lib/`); a test needs no `runAsync`. A form that is dropped with its page disposes its
  controllers, so a `LeakTesting` run finds nothing left behind.
