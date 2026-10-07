# Forms: fespalier_forms

`fespalier_forms` (since 0.11.0) is the form of an [`action.dart`](actions.md): typed fields with controllers the form owns, validation, the server's errors under their fields and a pending state. Before 0.11.0 it was part of `fespalier`; it moved out so an app with no forms ships none of it.

It is a companion package like `fespalier_flags`: no file kind of its own, no `fespalier:` key and no `fsp` command. You write a `form()` beside an action, `fsp gen` writes a `useForm` hook for it, and the hook returns the form.

What stays in `fespalier` because it does not need a form: [`FieldErrors`](actions.md#validate-and-fielderrors), the `validate()` that runs inside the action's provider (so `submit`, `useAction` and a test through the provider are refused the same way), and [`optimistic()`](actions.md#optimistic-updates-optimistic).

## Install

Add `fespalier_forms` under `dependencies:` next to `fespalier`, with the same git `url` and the same `ref`: pub resolves the two to one package only if they are the same repository dependency. The snippet, kept at the release's tag, is in [`packages/fespalier_forms/README.md`](../packages/fespalier_forms/README.md).

Then run `flutter pub get` and `fsp gen` (restart `fsp watch` or `fsp dev` if one is running, so it reads the new dependency). The generated file imports `package:fespalier_forms/fespalier_forms.dart` when some `action.dart` has a `form()`, and an app without a form does not import it. An app that has a `form()` and no `fespalier_forms` in `pubspec.yaml` gets an error at the `form()`:

```text
✗ (account)/nickname/action.dart:6  `form()` is the form of `action()`, and since 0.11.0 forms are in the fespalier_forms package: add `fespalier_forms` under `dependencies:` in pubspec.yaml, with the same git `url` and `ref` as fespalier
```

Pages use inferred types (`final form = NicknameRoute.useForm(ref, data: profile)`), so they need no import. Code that names `ActionForm`, `ActionField`, `ActionTextField`, `ActionFormFields`, `FieldCodec`, `ActionFormMessages`, `ActionFormValidation` or `useActionForm` imports `package:fespalier_forms/fespalier_forms.dart`: `package:fespalier` no longer exports them.

## `form()` and `useForm`

A form is the UI of one write, so it is not a file kind: `form()` is a _companion function_ in the `action.dart` of the action it belongs to, found by name. For the action called `action` it is `form`; for any other action, say `approve`, it is `approveForm` (and `useApproveForm`). A companion is never read as an action, even when it takes a `Ref` (that is an error).

```dart
// lib/app/(account)/nickname/action.dart
/// The input of the action, and so the fields of its form: a record with named fields.
typedef NicknameFields = ({String nickname, int? age, bool newsletter});

/// The form starts from the data the page passes (the profile it shows).
NicknameFields form(Profile profile) =>
    (nickname: profile.nickname, age: profile.age, newsletter: profile.newsletter);

/// Checked on the device before the action runs, and live in the form after a first submit.
FieldErrors? validate(NicknameFields input) => FieldErrors({
  if (input.nickname.trim().isEmpty) 'nickname': 'Enter a nickname',
  if (input.age case final age? when age < 13) 'age': 'You must be 13 or older',
});

/// The server has the last word: it can throw `FieldErrors({'nickname': 'That nickname is taken'})`.
Future<Profile> action(Ref ref, {required NicknameFields input}) => …;
```

```dart
// the page: a HookConsumerWidget, because useForm is a real hook
final form = NicknameRoute.useForm(ref, data: profile);
final f = form.fields;                         // a record of typed fields
TextField(
  controller: f.nickname.controller,
  decoration: InputDecoration(errorText: f.nickname.error),
),
CheckboxListTile(value: f.newsletter.value, onChanged: f.newsletter.didChange, …),
if (form.error case final e?) Text('$e'),      // what is not one field's
FilledButton(onPressed: form.onSubmit, child: …),  // null while the action runs: disabled
TextButton(onPressed: form.isDirty ? form.reset : null, child: …),
```

- **The input is a record with named fields**, written inline (`required ({int amount, String note}) input`) or as a `typedef` declared in the same `action.dart`; the generator reads the field names and types from there and nowhere else. `form()` returns exactly the input's type (as written) and takes no `Ref`: it takes the data the form starts from, or nothing.
- **`useForm`** is the generated member (`useApproveForm` for `approve`). **It is a real hook**: call it from a `HookConsumerWidget`'s `build` (`useAction` is not one).
  - It takes the action's keys, `data:` (only when `form()` takes a parameter; then required and of that type), and `validation:`, `resetOnSuccess:` and `messages:`. A key of the action can't be called `data`, `validation`, `resetOnSuccess` or `messages`.
  - It returns an `ActionForm` with `fields`, `state`, `isPending`, `isDirty`, `isValid`, `error`, `onSubmit`, `submit()` and `reset()`.
- **Initial values and new data.** The form starts from `form(data)`.
  - When the page gets another data object (the action invalidated the data, or it was refreshed), the fields the user has not changed follow it, and the changed ones keep what was typed.
  - While the form's own action is running the data is not read again: during an optimistic write the page gets the patched value, and a rollback would otherwise wipe what was typed.
  - `reset()` goes back to the data the form was last given and clears the errors and the action's state. After a success the fields become the new baseline (`isDirty` is false); `resetOnSuccess: true` restarts them from `form(data)` instead.

## Fields

Fields are typed by the record's field types.

- `String`, `int`, `double`, `num` and their nullable forms are **text fields** with a `controller` that the form owns and disposes. An empty nullable one is `null`, an empty non-nullable number is `Required`, a bad number is `Enter a whole number` or `Enter a number`.
- Any other type (`bool`, an enum, a `DateTime`, a list) is a **value field**: bind it with `value` and `didChange(v)`, which ignores `null` for a non-nullable type so it fits `Checkbox.onChanged`.
- **Messages.** Pass `messages: ActionFormMessages(required: ..., integer: ..., number: ...)` to `useForm` to translate the three texts a field produces by itself.
- **Validation timing.** `validation: ActionFormValidation.afterSubmit` (the default) shows nothing before the first submit and every field as it changes after; `onChange` shows a field once the user has changed it.

## Submit and errors

- **Submit.** `onSubmit` (or `submit()`) reads the text fields, then asks `validate()`. If anything is wrong it stops there and **the action is not called**; otherwise it runs the action with the record the fields make. A sync action stays sync: `submit()` returns its value at once. `onSubmit` is `null` while the action runs, so `FilledButton(onPressed: form.onSubmit)` disables itself.
- **Errors per field.** A field shows, in this order: its own parse error, the `FieldErrors` the action threw for its name (until that field is edited), and what `validate()` says of it.
- **`form.error`** is what is not one field's: `FieldErrors.message`, the messages of keys that are no field, or the error of an action that failed otherwise.
- **`validate()`** is `FieldErrors? validate(Input input)`: see [`validate()` and `FieldErrors`](actions.md#validate-and-fielderrors). The form asks it too, so a check written once guards the form, `submit` and a test.
- **The server's answer.** A check the device can't make belongs in the action, which throws `FieldErrors({'nickname': 'That nickname is taken'})`. The [HTTP package](http.md#server-validation-errors-on-forms) maps a server's validation answer to it.
- **A write is never retried**, as for any [action](actions.md#actiondart-typed-writes): a failed submit shows its error, and trying again is the user's call.

## Testing

A form is tested through its page: `pumpRouter` boots the app at the location (see [Testing](testing.md)), `enterText` and `tap` drive it, and the pending write is held on a `Completer`, so no timer and no `runAsync` is needed.

```dart
testWidgets('a taken nickname is shown under its field', (tester) async {
  server.taken = 'bob';
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/nickname'),
    overrides: [profileServerProvider.overrideWithValue(server)],
  );
  await tester.enterText(find.widgetWithText(TextField, 'Nickname'), 'bob');
  await tester.tap(find.text('Save'));
  await tester.pump();
  expect(find.text('That nickname is taken'), findsOneWidget);
});
```

- **Hold the save** on a `Completer` in your fake server to look at the pending state (`onSubmit` is `null`), then complete it and `pump`.
- **`package:fespalier_forms/testing.dart`** has `isFieldErrors(fields, message:)`, a matcher for the `FieldErrors` an action throws: `expectLater(run(input), throwsA(isFieldErrors({'nickname': 'Taken'})))`.
- **`examples/features`** has `test/forms_test.dart`: validation, errors per field, a pending submit, reset, and an optimistic patch that the server's value replaces.
- A form disposes its controllers with the page; a test under `LeakTesting` finds nothing left behind.
- The package starts no timer, schedules no microtask and reads no clock (`test/no_timers_test.dart` checks `lib/`).
