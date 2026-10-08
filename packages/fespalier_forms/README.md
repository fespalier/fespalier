# fespalier_forms

Forms for [fespalier](https://github.com/fespalier/fespalier) (since 0.11.0): the `form()` of an `action.dart` becomes a
generated `useForm` hook that returns a form with typed fields, validation, the server's errors under their fields and a
pending state. Before 0.11.0 this lived in `fespalier` itself.

`FieldErrors`, `validate()` and `optimistic()` stay in `fespalier`: they are how an action says which fields are wrong,
and they work without a form.

The full guide is [docs/forms.md](https://github.com/fespalier/fespalier/blob/main/docs/forms.md). This page is the short
version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if they are
the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.13.1
  fespalier_forms:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_forms
      ref: v0.13.1
```

<!-- x-release-please-end -->

Then run `fsp gen`: the generated `lib/app.g.dart` imports `package:fespalier_forms/fespalier_forms.dart` when an
`action.dart` has a `form()`, and `fsp` reports an error until the dependency is in `pubspec.yaml`.

## Use it

```dart
// lib/app/(account)/nickname/action.dart
typedef NicknameFields = ({String nickname, int? age});

NicknameFields form(Profile profile) => (nickname: profile.nickname, age: profile.age);

FieldErrors? validate(NicknameFields input) =>
    FieldErrors({if (input.nickname.trim().isEmpty) 'nickname': 'Enter a nickname'});

Future<Profile> action(Ref ref, {required NicknameFields input}) => …;
```

```dart
// the page: a HookConsumerWidget, because useForm is a real hook
final form = NicknameRoute.useForm(ref, data: profile);
final f = form.fields;
TextField(controller: f.nickname.controller, decoration: InputDecoration(errorText: f.nickname.error)),
FilledButton(onPressed: form.onSubmit, child: const Text('Save')),
```

## Drafts

Pass `draft: const FormDraft()` to a `useForm` to keep what the user typed per route and restore it when the route is
opened again: written when the page goes and when the app goes to the background, never per keystroke, deleted by a
successful submit or `reset()`. It is opt-in for each form (`FormDraft(exclude: {'password'})` keeps a field out), goes
to `formDraftStorage` (your `dataCacheStorage` by default) and is scoped by `formDraftScope`; call `clearFormDrafts` at
sign-out. See [Drafts](https://github.com/fespalier/fespalier/blob/main/docs/forms.md#drafts) in the guide.

## Leaving with unsaved changes

A form registers itself with the page's `leave.dart`, and `leaveIfClean` is the whole `leave()` that asks, in a bottom
sheet, before a changed form goes: "Keep editing", "Discard" and, for a form with a `draft:`, "Keep as draft".

```dart
LeaveResult leave(BuildContext context, Ref ref, {required PageLeave page}) =>
    leaveIfClean(context, ref, page);
```

The sheet is Flutter's (`showModalBottomSheet`); `leavePrompt` is the app's question, to translate with
`LeaveSheetMessages` or to override with a sheet of your own (an app on material_ui's `MaterialApp` has to). See
[Leaving with unsaved changes](https://github.com/fespalier/fespalier/blob/main/docs/forms.md#leaving-with-unsaved-changes).

## Testing

`package:fespalier_forms/testing.dart` has `isFieldErrors`, a matcher for the `FieldErrors` an action throws,
`LeavePrompts.answer(LeaveChoice)` to answer the leave question without a sheet, and
`seedFormDraft` and `readFormDraft` for a form's draft. A form is tested through the page with `pumpRouter` (see the
guide).

## Coming from before 0.11.0

`ActionForm`, `ActionField`, `ActionTextField`, `ActionFormFields`, `FieldCodec`, `ActionFormMessages`,
`ActionFormValidation` and `useActionForm` are exported by `package:fespalier_forms/fespalier_forms.dart` and no longer
by `package:fespalier/fespalier.dart`; the names are the same. See the migration notes in
[docs/migration.md](https://github.com/fespalier/fespalier/blob/main/docs/migration.md).
