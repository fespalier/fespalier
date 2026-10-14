# Models, collections, validation and results

Since 0.17.0, and only advice: **fespalier depends on none of these packages**, and `fsp` reads none of them
(it does not know what `@freezed` is). They meet it in six places, and each has one trap:

| Where                              | What it needs from your type                                                                                                                     | The trap                                                                                                                                      |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| The value `data()` returns         | `==`. Riverpod 3 filters every update by `==`, so an equal reload is not a change                                                                | A class with no `==` is a new value on every reload; a list field is compared by identity (below)                                             |
| An `extra`                         | `toJson` and `fromJson`, in `extra_codec.dart`                                                                                                   | freezed's factory syntax makes a private `_Note`: `ExtraCodec.of`, not `ExtraCodec({...})` (`fespalier-routing`, `typed-routes-and-extra.md`) |
| `DataCache<T>.json`                | `toJson` that returns **JSON data** (a `Map`), and `fromJson` that takes `Object?`                                                               | dart_mappable's `toJson()` returns a **String**: pass `toMap`                                                                                 |
| An action's `input`                | Any type, but a **form** (`form()`, `useForm`) needs a **record** declared in the same `action.dart` (`forms.md`)                                | A model class is not supported as a form's input: map the record to your model inside `action()`                                              |
| `validate()`                       | A pure `FieldErrors? validate(Input input)`; any library is an adapter around it (below)                                                         | It runs in the form **and** in the action, before the write                                                                                   |
| Failures, from `data()`/`action()` | They **throw**: `error.dart` gets the object as `Object error`, an action's failure lands in its `state`, `FieldErrors` under the field it names | Do not return a result from `data()`: unwrap it there (below)                                                                                 |

`fsp` itself writes no model code and the scaffolds use no `build_runner`; the apps that do use it should read
**`fespalier-troubleshooting`, `references/flutter-pitfalls.md`**, "`lib/app.g.dart` vanishes after `build_runner`":
with a `lib/app.dart`, json_serializable and the other `.g.dart` builders make `build_runner` delete fespalier's
default output. `build_runner` needs no `-d` (it has ignored the flag since 2.7.0).

## Which model library

Pick by the Dart your app builds with, since the newest releases moved up:

| Dart (Flutter)             | Take                                                                                     | Notes                                                                                                                                                   |
| -------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 3.13 (Flutter 3.47)        | **freezed 4.0.2**, or records and primary constructors with no codegen, or dart_mappable | freezed 4 needs Dart 3.13. Its new syntax is a primary constructor (`@freezed class Person({...}) with _$Person;`); the factory syntax still works      |
| 3.9 to 3.12 (3.35 to 3.44) | **freezed 3.2.5** (Dart 3.8), or dart_mappable 4.10.0 (Dart 3.7)                         | freezed 4 does not resolve below Dart 3.13. json_serializable 6.14.1 needs Dart 3.9, fespalier's own floor                                              |
| any                        | **dart_mappable 4.10.0**: one builder for `==`, `copyWith` and a `Map`/JSON conversion   | `class Order with OrderMappable`; `toMap()` and `OrderMapper.fromMap(map)` are the data, `toJson()` is a String. Its classes are their own runtime type |

- **freezed's two syntaxes are not the same to `ExtraCodec`.** `const factory Note(...) = _Note;` builds a `_Note`
  (an exact type lookup misses it: `ExtraCodec.of`, since 0.17.0); the primary-constructor form and dart_mappable
  classes are their own runtime type.
- **Equality is why you want one.** freezed, dart_mappable and records have `==` by value, so a `Stream<T>` or a
  reloaded `Future<T>` of equal values wakes nothing up. A hand-written `==` that compares a `List` field with `==`
  compares identity (below).
- built_value and built_collection are not recommended: builders for everything, and built_value's implementation
  class is private in the same way as freezed's (so expect the same `ExtraCodec` trap; not run here).

```dart
// extra_codec.dart: freezed (factory syntax), json_serializable's fromJson and toJson
final extraCodec = ExtraCodec.of([
  ExtraType<Note>(toJson: (n) => n.toJson(), fromJson: Note.fromJson),
  ExtraType<Order>(toJson: (o) => o.toMap(), fromJson: OrderMapper.fromMap), // dart_mappable: toMap, not toJson
]);

// data.dart
final dataCache = DataCache<Note>.json(
  toJson: (n) => n.toJson(),
  fromJson: (j) => Note.fromJson(j! as Map<String, Object?>),
);
```

`ci/codegen-interop/` in the fespalier repository is this with real freezed 4, json_serializable and `build_runner`
(`just codegen-interop`); the blocks above are fragments because a sample that needs generated parts cannot be built here.

## Records and primary constructors (Dart 3.13, no codegen)

Dart 3.13 (August 2026) added **primary constructors**, so an immutable class is one line, and records have had
value equality since 3.0. Neither has `copyWith`, JSON or `==` **on a class**: a class from a primary constructor
compares by identity, so a `data()` that returns one is a new value on every reload. Use a **record** for a small
value (it is what a form's input is), and a generator for a class that needs `==` or JSON.

```dart
// Dart 3.13 (sdk: ^3.13.0): a page whose constructor is the class header.
class const NotePage({super.key, required final int id}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Text('note $id');
}
```

`fsp` reads this: the parameters of a primary constructor bind to the segments and query parameters by name,
exactly as the parameters of a normal constructor do (`dart.rs` blanks the class header and reads the parameter list
apart, since the grammar it uses does not know the syntax yet; checked with Dart 3.13.4: `fsp gen` and `flutter analyze`
pass). In a primary constructor a parameter that should be a field says `final` (`required final int id`) and
`super.key` does not. An app on Dart 3.12 or earlier writes the old constructor, and a page of either kind works the
same.

## Collections: `fast_immutable_collections` and `select`

A page that reads one field of its data, `ref.watch(ArticleRoute.data(id).select((v) => v.value?.tags))`, wakes up when
that field is **not `==` to the last one**. freezed's `==` on the class is deep, but the list it hands out is not equal
to another list with the same items: its `tags` is an `EqualUnmodifiableListView`, whose `==` compares the two
underlying lists, and a `List` is only equal to itself. So a selected list **notifies after every reload that decoded a
new list, equal or not** (measured with freezed 4.0.2 and Riverpod 3.4.3: `Note(tags: ['x']) == Note(tags: ['x'])` is
`true`, `a.tags == b.tags` is `false`, and after one equal reload of a decoded `Note` a `select((v) => v.value?.tags)`
had notified twice, the whole value once). An `IList` from `fast_immutable_collections` 12 (deep `==` by default) does
not.

```yaml
# pubspec.yaml dependencies
  fast_immutable_collections: ^12.0.0
```

```dart
// lib/models.dart
import 'package:fast_immutable_collections/fast_immutable_collections.dart';

/// Equal by value, as freezed's classes are, with both kinds of list.
class Article {
  const Article(this.id, this.list, this.ilist);

  final int id;
  final List<String> list;
  final IList<String> ilist;

  @override
  bool operator ==(Object other) =>
      other is Article &&
      other.id == id &&
      other.list.length == list.length &&
      Iterable<int>.generate(list.length).every((i) => list[i] == other.list[i]) &&
      other.ilist == ilist;

  @override
  int get hashCode => Object.hash(id, Object.hashAll(list), ilist);
}
```

```dart
// lib/app/articles/$id/data.dart
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:fespalier/fespalier.dart';
import 'package:my_app/models.dart';

/// New lists on every call, as a decoded response is.
Future<Article> data(Ref ref, {required int id}) async =>
    Article(id, ['x'], IList(['x']));
```

```dart
// lib/app/articles/$id/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/models.dart';

class ArticlePage extends StatelessWidget {
  const ArticlePage({super.key, required this.id, required this.data});

  final int id;
  final Article data;

  @override
  Widget build(BuildContext context) => Text('article $id: ${data.list}');
}
```

```dart
// test/select_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';

void main() {
  test('select of a List notifies on an equal reload; an IList does not', () async {
    final container = ProviderContainer(retry: (_, _) => null);
    addTearDown(container.dispose);
    final provider = ArticleRoute.data(1);
    var lists = 0;
    var ilists = 0;
    container.listen(provider.select((v) => v.value?.list), (_, _) => lists++);
    container.listen(provider.select((v) => v.value?.ilist), (_, _) => ilists++);

    await container.read(provider.future);
    expect((lists, ilists), (1, 1)); // the first value: both change from null

    container.invalidate(provider); // an equal reload
    await container.read(provider.future);
    expect(ilists, 1); // nothing new: the IList is equal
    expect(lists, 2); // a new List object, equal or not
  });
}
```

- **The finding:** one equal reload gave the `List` selector a second notification and the `IList` selector none.
  Selecting the whole value never notifies on an equal reload (the provider filters by `==`). The same list instance
  (a `const` list the data function returns every time) is equal to itself, so measure with what your data layer
  really returns: a decoded response is a new list.
- Use it for **list-valued data** (`Future<IList<Hit>> data(...)`) and for a model field a page `select`s. A freezed
  or dart_mappable field of that type needs JSON conversion for the `IList` (not built here). It is a dependency of
  **your app**: fespalier's own `QueryList` (a `List` query parameter, with value equality) is 20 lines and stays.
- 12.0.0 (Dart 3.5) changed one thing: with deep equality turned **off**, `==` is `identical`. Leave it on.

## Validation: `validate()` stays a plain function

`FieldErrors? validate(Input input)` is the one hook, and a function you write is the default: no package needed
for "not empty" or "at least 3 characters". A schema library earns its place for **many** rules, nested objects and
one schema that also exports JSON Schema or OpenAPI. It is an **adapter inside `validate()`**, never a replacement for it.

- **acanthis 2.0.0** (Zod-like; **Dart 3.13**) returns a sealed outcome from `tryParse`; turn its issues into the
  record's field names. (acanthis 2 also has `validate`, which gives the first message or null for **one** field.)
  Below Dart 3.13 the newest is 1.6.0 (Dart 3.10) or 1.5.0 (Dart 3.8 and up), with a different result type: not covered here.
- **luthor 0.18.0** (Dart 3.8) has the same shape (a schema over a `Map`) and a generator, `@luthor` on a freezed or
  dart_mappable class, that writes the `$XValidate` helper. Neither the generator nor luthor itself is built in
  this page: adapt it as below.
- **One function for a form and a query.** A `guard.dart` or `redirect.dart` that takes `{int? page}` can call the
  same `validatePage(page)`: the query parameter is already typed and parsed, so a schema library adds nothing there.

```yaml
# pubspec.yaml dependencies
  acanthis: ^2.0.0
  result_dart: ^2.2.0
  fpdart: ^1.2.0
```

```dart
// lib/app/nickname/action.dart
import 'package:acanthis/acanthis.dart' as acanthis;
import 'package:fespalier/fespalier.dart';

typedef NicknameFields = ({String nickname, int? age});

final _schema = acanthis.object({
  'nickname': acanthis.string().min(3).max(12),
  'age': acanthis.integer().gte(18).nullable(),
});

/// Runs in the form and in the action, before the write. The first message of each field.
FieldErrors? validate(NicknameFields input) {
  final outcome = _schema.tryParse({'nickname': input.nickname, 'age': input.age});
  return switch (outcome) {
    acanthis.AcanthisValid() => null,
    acanthis.AcanthisInvalid(:final issues) => FieldErrors({
      for (final issue in issues.reversed) issue.path.join('.'): issue.message,
    }),
  };
}

Future<String> action(Ref ref, {required NicknameFields input}) async => input.nickname;
```

```dart
// lib/app/nickname/page.dart
import 'package:flutter/material.dart';

class NicknamePage extends StatelessWidget {
  const NicknamePage({super.key});

  @override
  Widget build(BuildContext context) => const Text('nickname');
}
```

```dart
// test/nickname_validate_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app/nickname/action.dart';

void main() {
  test('the schema is what validate() answers with', () {
    final errors = validate((nickname: 'a', age: 3))!;
    expect(errors.fields.keys, unorderedEquals(['nickname', 'age']));
    expect(validate((nickname: 'abcd', age: null)), isNull);
  });
}
```

## Failures and results

The default needs no package: **sealed failure classes, thrown**. `data()` and `action()` throw, Riverpod holds the
object in an `AsyncValue`, and `error.dart` switches on its type.

```dart
// lib/failures.dart
sealed class AppFailure implements Exception {
  const AppFailure();
}

final class NotFound extends AppFailure {
  const NotFound();
}

final class Offline extends AppFailure {
  const Offline();
}

final class Taken extends AppFailure {
  const Taken();
}
```

When the data layer already returns a result, **unwrap it in `data()`**, not above it: a `data()` that returns
`Result` makes `error.dart` unreachable (the future never fails). With **result_dart 2.2** `getOrThrow()` throws the
failure object itself; with **fpdart 1.2** it is `getOrElse((l) => throw l)`. **fpdart 2 is a pre-release
(`2.0.0-dev.3`)**: do not build on it. In an `action()`, map the failures that belong under a field to `FieldErrors`
and rethrow the rest.

```dart
// lib/api.dart
import 'package:fespalier/fespalier.dart';
import 'package:fpdart/fpdart.dart' as fp;
import 'package:my_app/failures.dart';
import 'package:result_dart/result_dart.dart';

class Note {
  const Note(this.id, this.title);

  final int id;
  final String title;
}

class NotesApi {
  Future<ResultDart<Note, AppFailure>> note(int id) async =>
      id == 404 ? const Failure(NotFound()) : Success(Note(id, 'Note $id'));

  Future<ResultDart<Note, AppFailure>> rename(int id, String title) async =>
      title == 'taken' ? const Failure(Taken()) : Success(Note(id, title));

  /// The same lookup in fpdart's types.
  fp.Either<AppFailure, Note> noteEither(int id) =>
      id == 404 ? fp.left(const NotFound()) : fp.right(Note(id, 'Note $id'));
}

/// fpdart's way to unwrap: `getOrElse` with a throw.
Note unwrap(fp.Either<AppFailure, Note> either) =>
    either.getOrElse((failure) => throw failure);

final notesApiProvider = Provider<NotesApi>((ref) => NotesApi());
```

```dart
// lib/app/notes/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/api.dart';

Future<Note> data(Ref ref, {required int id}) async =>
    (await ref.read(notesApiProvider).note(id)).getOrThrow();
```

```dart
// lib/app/notes/$id/error.dart
import 'package:flutter/material.dart';
import 'package:my_app/failures.dart';

class NoteError extends StatelessWidget {
  const NoteError({
    super.key,
    required this.id,
    required this.error,
    required this.retry,
  });

  final int id;
  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => switch (error) {
    NotFound() => Text('No note #$id'),
    Offline() => TextButton(onPressed: retry, child: const Text('Offline: try again')),
    _ => TextButton(onPressed: retry, child: Text('Something broke: $error')),
  };
}
```

```dart
// lib/app/notes/$id/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/api.dart';

class NotePage extends StatelessWidget {
  const NotePage({super.key, required this.id, required this.data});

  final int id;
  final Note data;

  @override
  Widget build(BuildContext context) => Text(data.title);
}
```

```dart
// lib/app/notes/$id/action.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/api.dart';
import 'package:my_app/failures.dart';

typedef RenameFields = ({String title});

/// A taken title is the form's to show, under its field; anything else is the write's error.
Future<Note> action(Ref ref, {required int id, required RenameFields input}) async {
  final result = await ref.read(notesApiProvider).rename(id, input.title);
  return result.fold(
    (note) => note,
    (failure) => throw switch (failure) {
      Taken() => const FieldErrors({'title': 'That title is taken'}),
      _ => failure,
    },
  );
}
```

```dart
// test/notes_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/api.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/failures.dart';

void main() {
  testWidgets('a result is unwrapped in data(), and error.dart switches on the failure', (
    tester,
  ) async {
    await pumpRouter(tester, AppRoutes.router(initialLocation: '/notes/404'));
    expect(find.text('No note #404'), findsOneWidget);
  });

  testWidgets('a result that succeeds is the page\'s data', (tester) async {
    await pumpRouter(tester, AppRoutes.router(initialLocation: '/notes/7'));
    expect(find.text('Note 7'), findsOneWidget);
  });

  test('a failure that belongs to a field becomes FieldErrors, another is rethrown', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final rename = container.read(NoteRoute.action(1).notifier);
    await expectLater(rename.call((title: 'taken')), throwsA(isA<FieldErrors>()));
    expect((await rename.call((title: 'new'))).title, 'new');
  });

  test('fpdart: getOrElse with a throw unwraps an Either', () {
    final api = NotesApi();
    expect(unwrap(api.noteEither(2)).title, 'Note 2');
    expect(() => unwrap(api.noteEither(404)), throwsA(isA<NotFound>()));
  });
}
```

**What is not built:** a model class as a form's `input` (it is a record: map it in `action()`), a code generator for
`ExtraCodec` or `DataCache` entries (you write them), and any package-specific integration in `fsp` or the runtime.
