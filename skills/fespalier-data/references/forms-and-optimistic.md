# Forms and optimistic updates on `action.dart`

Since 0.8.1 (`cli/src/forms.rs` for the names, `packages/fespalier/lib/src/action_form.dart` and
`optimistic.dart` for the runtime). There is **no `form.dart`**: `form()`, `validate()` and
`optimistic()` are _companion functions_ in the `action.dart` of the action they belong to.
An app on 0.7.0 or earlier has none of this; one that writes no companion generates exactly what
0.7.0 did.

**The names.** For the action called `action` a companion is the role itself (`form`,
`validate`, `optimistic`). For any other action, `approve` say, it is `approveForm`,
`approveValidate`, `approveOptimistic`, and the form hook is `useApproveForm`. A companion is
**never an action**, even when it takes a `Ref` (that is an error, below): an app on 0.7.0 that
had an _action_ called `form` beside `action` must rename it.

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

import 'package:fespalier/testing.dart';
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
  typed as that parameter) and `validation:`, `resetOnSuccess:`, `messages:`. **`data:` is what the
  page got**: pass the page's own `profile`, which is the data with the optimistic patch while a
  write is in flight. A key of the action named `data`, `validation`, `resetOnSuccess` or
  `messages` is an error.
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
- **Not built**: async per-field validators, a control tree, custom text codecs for dates and
  enums (use a picker and a value field), an `fsp new --form` scaffold.

## `validate()`: the same check in every path

`FieldErrors? validate(Input input)`: one positional typed parameter (the action's input as
written), no `Ref`, no record needed. It runs in the form, live, **and inside the action's
provider before the action**: `submit`, `useAction`'s `call` and `container.read(...notifier).call`
all go through it. A refused input never starts the write: no loading state, the `FieldErrors` is
thrown synchronously (`call` of the handle returns `null`; `submit` throws), and `state` and
`ActionHandle.fieldErrors` hold it. A check that needs the server belongs in the action:
`throw const FieldErrors({'nickname': 'That nickname is taken'})`. The keys are the record's field
names; `FieldErrors(fields, message:)` also takes a form-level `message`.

## `optimistic()`: the page before the server answers

`T optimistic(T current, Input input)`: two positional typed parameters, returning the first's
type, no `Ref`. It patches **one `data.dart` the action invalidates**, found by the type `T`.

- **The target is searched among what the action invalidates**: this folder's own data first, then
  the sections above it (innermost first), then the rest of `invalidates` in the order listed.
  Nothing of type `T` there is an error (O3a, O3b). So `const invalidates = <Object>[]` beside an
  `optimistic()` is an error, and a custom `invalidates` must list the target. Only the target is
  patched.
- **The sequence.** The patch shows from the start of the write. A failure removes it (the
  rollback). A success keeps it **over the old value until the invalidated data has loaded again**,
  so no frame shows the old value, with `keep_previous: false` too: while a patched write settles,
  `DataView` skips `loading.dart`. Then the server's value shows. A write that is not patched
  shows `loading.dart` as configured.
- **Concurrent writes** apply oldest first; a failure removes only its own patch.
- **Which reads are patched**: `DataView`, `SectionView` (a section's layout and every page
  below it that takes the section's data by type), and the typed `XRoute.watch` /
  `XSection.watch`. **Not patched, the server's value**: `XRoute.data`, `read`, `refresh`,
  `prefetch`, `preload`, `AppRoutes.dataAt`, and `ref.watch(XRoute.data)` anywhere. A
  dependency-triggered reload (`AsyncLoading` with a value) is unpatched in `watch` only.
- **The patch ends with the reload, not with a comparison**: a `data()` that returns the very same
  object after loading still drops it. A patch that throws is reported through
  `FlutterError.reportError` (`while applying an optimistic() patch`) and skipped.
- The page can leave mid-write: the write still finishes and still invalidates.

## Testing a form

Hold the save on a `Completer` and `pump()`; no timer, no `runAsync` (the `// test/` sample above).
`enterText` on the `TextField` types into the field's controller; `onSubmit` is the button's
`onPressed`, `null` while pending. For a section, `TeamsTeamIdSection.addMember(ref, ...)` from the
page's element (`tester.element(find.byType(MembersPage)) as WidgetRef`), then pump in steps and
assert the list never loses the new member.
