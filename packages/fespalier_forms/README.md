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
      ref: v0.10.0
  fespalier_forms:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_forms
      ref: v0.10.0
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

## Testing

`package:fespalier_forms/testing.dart` has `isFieldErrors`, a matcher for the `FieldErrors` an action throws. A form
is tested through the page with `pumpRouter` (see the guide).

## Coming from before 0.11.0

`ActionForm`, `ActionField`, `ActionTextField`, `ActionFormFields`, `FieldCodec`, `ActionFormMessages`,
`ActionFormValidation` and `useActionForm` are exported by `package:fespalier_forms/fespalier_forms.dart` and no longer
by `package:fespalier/fespalier.dart`; the names are the same. See the migration notes in
[docs/migration.md](https://github.com/fespalier/fespalier/blob/main/docs/migration.md).
