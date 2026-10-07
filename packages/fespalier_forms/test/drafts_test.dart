// ignore_for_file: prefer_function_declarations_over_variables
// (the generated file writes its route members as closures, so these do too)

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/persist.dart';
import 'package:fespalier_forms/fespalier_forms.dart';
import 'package:fespalier_forms/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What `fsp` generates for an `action.dart` with a `form()`, written by hand: the `useForm` with
/// `id:`, `key:`, `shape:` and `draft:`, and a `DraftCodec` on each value field it can keep.
/// Storages are in memory, so no test waits on a timer: an async storage is a `Completer`.

enum Mood { calm, loud }

typedef Fields = ({
  String nickname,
  int? age,
  bool newsletter,
  Mood mood,
  DateTime? since,
  String password,
});

Fields form() => (
  nickname: 'ann',
  age: null,
  newsletter: false,
  mood: Mood.calm,
  since: null,
  password: '',
);

/// Held while a test wants the write to be in flight.
Completer<void>? actionGate;

FutureOr<String> action(Ref ref, {required int id, required Fields input}) =>
    actionGate == null
    ? input.nickname
    : actionGate!.future.then((_) => input.nickname);

FieldErrors? validate(Fields input) => input.nickname == 'bad'
    ? const FieldErrors({'nickname': 'Not that'})
    : null;

const actionId = '(account)/nickname/action.dart#action';
const shape =
    'nickname:String,age:int?,newsletter:bool,mood:Mood,since:DateTime?,password:String';

final _action1 = actionFamily(
  (Ref ref, int id, Fields input) => action(ref, id: id, input: input),
  validate: validate,
  invalidates: (int id) => const <ProviderListenable<AsyncValue<Object?>>>[],
  site: 'a1_0',
);

typedef NicknameForm =
    ActionForm<
      Fields,
      String,
      ({
        ActionTextField<String> nickname,
        ActionTextField<int?> age,
        ActionField<bool> newsletter,
        ActionField<Mood> mood,
        ActionField<DateTime?> since,
        ActionTextField<String> password,
      })
    >;

abstract final class NicknameRoute {
  static final useForm =
      (
        WidgetRef ref, {
        required int id,
        String formShape = shape,
        String formId = actionId,
        FormDraft? draft,
      }) => useActionForm(
        ref,
        _action1(id),
        data: null,
        initial: form,
        fields: (ActionFormFields<Fields> f) => (
          nickname: f.text('nickname', (v) => v.nickname, FieldCodec.text),
          age: f.text('age', (v) => v.age, FieldCodec.optionalInteger),
          newsletter: f.value(
            'newsletter',
            (v) => v.newsletter,
            draft: DraftCodec.boolean,
          ),
          mood: f.value(
            'mood',
            (v) => v.mood,
            draft: DraftCodec.enumOf(Mood.values),
          ),
          since: f.value(
            'since',
            (v) => v.since,
            draft: DraftCodec.optionalDateTime,
          ),
          password: f.text('password', (v) => v.password, FieldCodec.text),
        ),
        validate: validate,
        input: (f) => (
          nickname: f.nickname.value,
          age: f.age.value,
          newsletter: f.newsletter.value,
          mood: f.mood.value,
          since: f.since.value,
          password: f.password.value,
        ),
        id: formId,
        key: [id],
        shape: formShape,
        draft: draft,
      );
}

NicknameForm? lastForm;

class NicknamePage extends HookConsumerWidget {
  const NicknamePage({
    super.key,
    this.id = 1,
    this.draft,
    this.formShape,
    this.formId = actionId,
  });

  final int id;
  final FormDraft? draft;
  final String? formShape;
  final String formId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = NicknameRoute.useForm(
      ref,
      id: id,
      draft: draft,
      formShape: formShape ?? shape,
      formId: formId,
    );
    lastForm = form;
    final f = form.fields;
    return Column(
      children: [
        TextField(
          key: const Key('nickname'),
          controller: f.nickname.controller,
        ),
        TextField(key: const Key('age'), controller: f.age.controller),
        TextField(
          key: const Key('password'),
          controller: f.password.controller,
        ),
        Text('dirty ${form.isDirty}'),
        TextButton(onPressed: form.onSubmit, child: const Text('Save')),
        TextButton(onPressed: form.reset, child: const Text('Reset')),
      ],
    );
  }
}

/// A storage that counts what reaches it, can answer later, and can fail.
final class SpyStorage extends Storage<String, String> {
  SpyStorage({this.readGate, this.fail = false});

  /// When given, `read` answers when it completes.
  Completer<void>? readGate;
  bool fail;
  final MemoryDataStorage inner = MemoryDataStorage();
  int writes = 0;
  int deletes = 0;
  final List<String> written = [];

  @override
  FutureOr<PersistedData<String>?> read(String key) {
    if (fail) throw StateError('read');
    final gate = readGate;
    if (gate == null) return inner.read(key);
    return gate.future.then((_) => inner.read(key));
  }

  @override
  void write(String key, String value, StorageOptions options) {
    if (fail) throw StateError('write');
    writes++;
    written.add(key);
    inner.write(key, value, options);
  }

  @override
  void delete(String key) {
    if (fail) throw StateError('delete');
    deletes++;
    inner.delete(key);
  }

  @override
  void deleteOutOfDate() {}
}

/// A storage whose writes finish when a test says so, as a disk's do.
final class LateWriteStorage extends Storage<String, String> {
  final MemoryDataStorage inner = MemoryDataStorage();
  Completer<void>? writeGate;

  @override
  PersistedData<String>? read(String key) => inner.read(key);

  @override
  FutureOr<void> write(String key, String value, StorageOptions options) {
    final gate = writeGate;
    if (gate == null) {
      inner.write(key, value, options);
      return null;
    }
    return gate.future.then((_) => inner.write(key, value, options));
  }

  @override
  void delete(String key) => inner.delete(key);

  @override
  void deleteOutOfDate() {}
}

/// `clearFormDraftsOf`, from the container of the page.
Future<void> clearAll(ProviderContainer container) =>
    container.read(Provider<Future<void>>((ref) => clearFormDraftsOf(ref)));

/// A storage whose reads answer when a test says so, holding a draft of [fields] for the form
/// with the family key 1.
Future<SpyStorage> slowStorage(Map<String, Object?> fields) async {
  final seed = MemoryDataStorage();
  final container = ProviderContainer(
    overrides: [formDraftStorage.overrideWithValue(seed)],
  );
  await seedFormDraft(
    container,
    id: actionId,
    key: [1],
    shape: shape,
    fields: fields,
  );
  container.dispose();
  const key = 'fespalier_forms.draft:$actionId:[1]';
  return SpyStorage(readGate: Completer<void>())
    ..inner.write(
      key,
      seed.read(key)!.data,
      StorageOptions(
        cacheTime: const StorageCacheTime(Duration(days: 7)),
        destroyKey: shape,
      ),
    );
}

/// The container of the app under test, for the helpers that take one.
ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(NicknamePage)));

final shown = ValueNotifier<bool>(true);

Widget app(
  FutureOr<Storage<String, String>?> storage, {
  String? scope,
  int id = 1,
  FormDraft? draft = const FormDraft(exclude: {'password'}),
  String? formShape,
  String formId = actionId,
}) => ProviderScope(
  overrides: [
    formDraftStorage.overrideWithValue(storage),
    formDraftScope.overrideWithValue(scope),
  ],
  retry: (_, _) => null,
  child: MaterialApp(
    home: Material(
      child: ValueListenableBuilder<bool>(
        valueListenable: shown,
        builder: (context, on, _) => on
            ? NicknamePage(
                id: id,
                draft: draft,
                formShape: formShape,
                formId: formId,
              )
            : const SizedBox(),
      ),
    ),
  ),
);

/// Leaves the page, as a route that is popped does.
Future<void> leave(WidgetTester tester) async {
  shown.value = false;
  await tester.pump();
}

/// The app goes to the background (as far as [stop]) and comes back.
void background(
  WidgetTester tester, {
  AppLifecycleState stop = AppLifecycleState.paused,
}) {
  final b = tester.binding;
  b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  if (stop == AppLifecycleState.paused) {
    b.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  b.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

String textOf(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

void main() {
  setUp(() {
    shown.value = true;
    lastForm = null;
  });

  testWidgets(
    'leaving a form that changed writes its draft; a clean one writes nothing',
    (tester) async {
      final storage = SpyStorage();
      await tester.pumpWidget(app(storage));
      await leave(tester);
      expect(storage.writes, 0);
      expect(storage.deletes, 0);

      shown.value = true;
      await tester.pump();
      await tester.enterText(find.byKey(const Key('nickname')), 'bob');
      await tester.enterText(find.byKey(const Key('age')), 'abc');
      await tester.pump();
      final container = containerOf(tester);
      await leave(tester);

      // Only what changed, the text as typed: the age is no number, and it survives.
      expect(
        await readFormDraft(container, id: actionId, key: [1], shape: shape),
        {'nickname': 'bob', 'age': 'abc'},
      );
    },
  );

  testWidgets(
    'a draft survives a restart and is restored before the first build',
    (tester) async {
      final storage = MemoryDataStorage();
      await tester.pumpWidget(app(storage));
      await tester.enterText(find.byKey(const Key('nickname')), 'bob');
      lastForm!.fields.newsletter.didChange(true);
      lastForm!.fields.mood.didChange(Mood.loud);
      lastForm!.fields.since.didChange(DateTime.utc(2026, 10, 7, 12));
      await tester.pump();
      await leave(tester);
      // Another run of the app: the storage is the only thing it shares.
      await tester.pumpWidget(const SizedBox());
      shown.value = true;
      await tester.pumpWidget(app(storage));

      // The sync storage restored inside the first build: no second pump was needed.
      expect(textOf(tester, 'nickname'), 'bob');
      expect(lastForm!.fields.newsletter.value, isTrue);
      expect(lastForm!.fields.mood.value, Mood.loud);
      expect(lastForm!.fields.since.value, DateTime.utc(2026, 10, 7, 12));
      expect(lastForm!.isDirty, isTrue);
      expect(find.text('dirty true'), findsOneWidget);
      // The fields nobody changed still follow the data.
      expect(textOf(tester, 'age'), '');
    },
  );

  testWidgets(
    'an async storage restores when it answers, into fields not touched since',
    (tester) async {
      final seed = MemoryDataStorage();
      await tester.pumpWidget(app(seed));
      await tester.enterText(find.byKey(const Key('nickname')), 'bob');
      await tester.enterText(find.byKey(const Key('age')), '41');
      await tester.pump();
      await leave(tester);

      final slow = SpyStorage(readGate: Completer<void>());
      for (final key in ['fespalier_forms.draft:$actionId:[1]']) {
        slow.inner.write(
          key,
          seed.read(key)!.data,
          StorageOptions(
            cacheTime: const StorageCacheTime(Duration(days: 7)),
            destroyKey: shape,
          ),
        );
      }
      await tester.pumpWidget(const SizedBox());
      shown.value = true;
      await tester.pumpWidget(app(slow));
      expect(textOf(tester, 'nickname'), 'ann');
      expect(find.text('dirty false'), findsOneWidget);

      // The user types before the storage answers: that field is theirs.
      await tester.enterText(find.byKey(const Key('nickname')), 'cy');
      slow.readGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(textOf(tester, 'nickname'), 'cy');
      expect(textOf(tester, 'age'), '41');
      expect(find.text('dirty true'), findsOneWidget);
    },
  );

  testWidgets('a storage that is a Future restores when it opens', (
    tester,
  ) async {
    final storage = MemoryDataStorage();
    await tester.pumpWidget(app(storage));
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    await leave(tester);

    final opening = Completer<Storage<String, String>?>();
    await tester.pumpWidget(const SizedBox());
    shown.value = true;
    await tester.pumpWidget(app(opening.future));
    expect(textOf(tester, 'nickname'), 'ann');
    opening.complete(storage);
    await tester.pump();
    await tester.pump();
    expect(textOf(tester, 'nickname'), 'bob');
  });

  testWidgets('exclude keeps a field out of the draft and out of the restore', (
    tester,
  ) async {
    final storage = MemoryDataStorage();
    await tester.pumpWidget(app(storage));
    await tester.enterText(find.byKey(const Key('password')), 'hunter2');
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    final container = containerOf(tester);
    await leave(tester);
    final saved = await readFormDraft(
      container,
      id: actionId,
      key: [1],
      shape: shape,
    );
    expect(saved, {'nickname': 'bob'});

    // Even a draft that holds it (written before it was excluded) does not put it back.
    await seedFormDraft(
      container,
      id: actionId,
      key: [1],
      shape: shape,
      fields: {'password': 'old', 'nickname': 'bob'},
    );
    await tester.pumpWidget(const SizedBox());
    shown.value = true;
    await tester.pumpWidget(app(storage));
    expect(textOf(tester, 'password'), '');
    expect(textOf(tester, 'nickname'), 'bob');
  });

  testWidgets('a form whose shape changed drops the drafts of the old one', (
    tester,
  ) async {
    final storage = SpyStorage();
    await tester.pumpWidget(app(storage));
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    await leave(tester);

    await tester.pumpWidget(const SizedBox());
    shown.value = true;
    await tester.pumpWidget(app(storage, formShape: 'nickname:int'));
    expect(textOf(tester, 'nickname'), 'ann');
    expect(storage.inner.read('fespalier_forms.draft:$actionId:[1]'), isNull);
  });

  testWidgets('a draft older than its maxAge is not restored', (tester) async {
    final storage = MemoryDataStorage();
    await tester.pumpWidget(
      app(storage, draft: const FormDraft(maxAge: Duration(days: 1))),
    );
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    await leave(tester);

    await tester.pumpWidget(const SizedBox());
    shown.value = true;
    final later = DateTime.now().add(const Duration(days: 2));
    await withClock(Clock.fixed(later), () async {
      await tester.pumpWidget(
        app(storage, draft: const FormDraft(maxAge: Duration(days: 1))),
      );
    });
    expect(textOf(tester, 'nickname'), 'ann');
  });

  testWidgets('a success deletes the draft, and so does reset', (tester) async {
    final storage = SpyStorage();
    await tester.pumpWidget(app(storage));
    const key = 'fespalier_forms.draft:$actionId:[1]';

    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    // Hidden, so the draft is written while the page is still here.
    background(tester, stop: AppLifecycleState.hidden);
    expect(storage.inner.read(key), isNotNull);

    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(storage.inner.read(key), isNull, reason: 'the success deleted it');

    await tester.enterText(find.byKey(const Key('nickname')), 'cy');
    await tester.pump();
    background(tester);
    expect(storage.inner.read(key), isNotNull);
    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(storage.inner.read(key), isNull, reason: 'reset deleted it');
    await leave(tester);
    expect(storage.inner.read(key), isNull, reason: 'nothing came back');
  });

  testWidgets('the app going to the background writes the draft once', (
    tester,
  ) async {
    final storage = SpyStorage();
    await tester.pumpWidget(app(storage));
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    expect(storage.writes, 0, reason: 'no write per keystroke');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(storage.writes, 0, reason: 'inactive is not leaving');
    background(tester);
    // The draft and the index entry, once: hidden and paused wrote the same thing.
    expect(storage.writes, 2);
    await leave(tester);
    expect(storage.writes, 2, reason: 'leaving wrote nothing new');
  });

  testWidgets('the family key and the scope make a draft somebody else\'s', (
    tester,
  ) async {
    final storage = MemoryDataStorage();
    await tester.pumpWidget(app(storage, scope: 'ann', id: 1));
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    await leave(tester);

    for (final other in [(scope: 'zed', id: 1), (scope: 'ann', id: 2)]) {
      await tester.pumpWidget(const SizedBox());
      shown.value = true;
      await tester.pumpWidget(app(storage, scope: other.scope, id: other.id));
      expect(textOf(tester, 'nickname'), 'ann', reason: '$other');
      await leave(tester);
    }
    await tester.pumpWidget(const SizedBox());
    shown.value = true;
    await tester.pumpWidget(app(storage, scope: 'ann', id: 1));
    expect(textOf(tester, 'nickname'), 'bob');
  });

  testWidgets('clearFormDrafts deletes every draft, whatever its scope', (
    tester,
  ) async {
    final storage = SpyStorage();
    for (final scope in ['ann', 'zed']) {
      await tester.pumpWidget(app(storage, scope: scope));
      await tester.enterText(find.byKey(const Key('nickname')), 'bob');
      await tester.pump();
      await leave(tester);
      await tester.pumpWidget(const SizedBox());
      shown.value = true;
    }
    expect(storage.inner.read('fespalier_forms.drafts'), isNotNull);

    late WidgetRef widgetRef;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [formDraftStorage.overrideWithValue(storage)],
        child: Consumer(
          builder: (context, ref, _) {
            widgetRef = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    await clearFormDrafts(widgetRef);
    for (final scope in ['ann', 'zed']) {
      expect(
        storage.inner.read('fespalier_forms.draft:$actionId:[1]:$scope'),
        isNull,
      );
    }
    expect(storage.inner.read('fespalier_forms.drafts'), isNull);
  });

  testWidgets('clearFormDraftsOf takes a Ref', (tester) async {
    final storage = MemoryDataStorage();
    final container = ProviderContainer(
      overrides: [formDraftStorage.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await seedFormDraft(
      container,
      id: actionId,
      shape: shape,
      fields: {'nickname': 'bob'},
    );
    final cleared = Provider<Future<void>>((ref) => clearFormDraftsOf(ref));
    await container.read(cleared);
    expect(await readFormDraft(container, id: actionId, shape: shape), isNull);
  });

  testWidgets(
    'a value a codec cannot read is dropped, the others are restored',
    (tester) async {
      final storage = MemoryDataStorage();
      await tester.pumpWidget(app(storage));
      final container = containerOf(tester);
      await leave(tester);
      await seedFormDraft(
        container,
        id: actionId,
        key: [1],
        shape: shape,
        fields: {'mood': 'furious', 'newsletter': true, 'nickname': 'bob'},
      );
      shown.value = true;
      await tester.pump();
      // The page is built again over the seeded storage.
      expect(lastForm!.fields.mood.value, Mood.calm);
      expect(lastForm!.fields.newsletter.value, isTrue);
      expect(textOf(tester, 'nickname'), 'bob');
    },
  );

  testWidgets(
    'a draft that is not JSON is dropped without a word to the user',
    (tester) async {
      final storage = MemoryDataStorage()
        ..write(
          'fespalier_forms.draft:$actionId:[1]',
          '{not json',
          StorageOptions(
            cacheTime: const StorageCacheTime(Duration(days: 7)),
            destroyKey: shape,
          ),
        );
      await tester.pumpWidget(app(storage));
      expect(textOf(tester, 'nickname'), 'ann');
      expect(storage.read('fespalier_forms.draft:$actionId:[1]'), isNull);
    },
  );

  testWidgets('a storage that throws never costs the page', (tester) async {
    final storage = SpyStorage(fail: true);
    await tester.pumpWidget(app(storage));
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    background(tester);
    await leave(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a form with no draft: or no storage keeps nothing', (
    tester,
  ) async {
    final storage = SpyStorage();
    await tester.pumpWidget(app(storage, draft: null));
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    background(tester);
    await leave(tester);
    expect(storage.writes, 0);

    shown.value = true;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(null));
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    await leave(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a page that goes after clearFormDrafts keeps nothing', (
    tester,
  ) async {
    final storage = MemoryDataStorage();
    await tester.pumpWidget(app(storage));
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    final container = containerOf(tester);
    await clearAll(container);
    await leave(tester);
    expect(
      await readFormDraft(container, id: actionId, key: [1], shape: shape),
      isNull,
    );
    expect(storage.read('fespalier_forms.drafts'), isNull);
  });

  testWidgets('a save in flight does not outlive a clear that came after it', (
    tester,
  ) async {
    final storage = LateWriteStorage()..writeGate = Completer<void>();
    await tester.pumpWidget(app(storage));
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    final container = containerOf(tester);
    background(tester); // the entry is being written, the gate is shut
    final cleared = clearAll(container);
    storage.writeGate!.complete();
    await cleared;
    await tester.pump();
    expect(storage.inner.read('fespalier_forms.draft:$actionId:[1]'), isNull);
    expect(storage.inner.read('fespalier_forms.drafts'), isNull);
  });

  testWidgets('a failed write does not stop the clear queued behind it', (
    tester,
  ) async {
    final storage = LateWriteStorage();
    await tester.pumpWidget(app(storage));
    final container = containerOf(tester);
    await seedFormDraft(
      container,
      id: actionId,
      key: [2],
      shape: shape,
      fields: {'nickname': 'old'},
    );
    storage.writeGate = Completer<void>();
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    background(tester);
    final cleared = clearAll(container);
    storage.writeGate!.completeError(StateError('disk full'));
    await cleared;
    expect(storage.inner.read('fespalier_forms.draft:$actionId:[2]'), isNull);
    expect(storage.inner.read('fespalier_forms.drafts'), isNull);
  });

  testWidgets('every save rewrites the index, so it is never the older', (
    tester,
  ) async {
    final storage = SpyStorage();
    await tester.pumpWidget(app(storage));
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.pump();
    background(tester);
    await tester.enterText(find.byKey(const Key('nickname')), 'bobby');
    await tester.pump();
    background(tester);
    expect(
      storage.written.where((k) => k == 'fespalier_forms.drafts'),
      hasLength(2),
    );
  });

  testWidgets('an async restore asks validate() again', (tester) async {
    final slow = await slowStorage({'nickname': 'bad'});
    await tester.pumpWidget(app(slow));
    expect(lastForm!.isValid, isTrue);
    slow.readGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(lastForm!.isValid, isFalse);
  });

  testWidgets('a draft that arrives while the action runs is skipped', (
    tester,
  ) async {
    final slow = await slowStorage({'age': '41'});
    actionGate = Completer<void>();
    addTearDown(() => actionGate = null);
    await tester.pumpWidget(app(slow));
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(lastForm!.isPending, isTrue);
    slow.readGate!.complete();
    await tester.pump();
    expect(textOf(tester, 'age'), '', reason: 'skipped while pending');
    actionGate!.complete();
    await tester.pump();
    await tester.pump();
  });

  testWidgets('a success that comes after the page is gone deletes the draft', (
    tester,
  ) async {
    final storage = MemoryDataStorage();
    actionGate = Completer<void>();
    addTearDown(() => actionGate = null);
    await tester.pumpWidget(app(storage));
    final container = containerOf(tester);
    await tester.enterText(find.byKey(const Key('nickname')), 'bob');
    await tester.tap(find.text('Save'));
    await tester.pump();
    await leave(tester); // the dirty form is written as it goes
    expect(
      await readFormDraft(container, id: actionId, key: [1], shape: shape),
      isNotNull,
    );
    actionGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(
      await readFormDraft(container, id: actionId, key: [1], shape: shape),
      isNull,
    );
  });

  testWidgets('a page that goes while its draft is still being read is safe', (
    tester,
  ) async {
    final slow = await slowStorage({'nickname': 'bob'});
    await tester.pumpWidget(app(slow));
    await leave(tester);
    slow.readGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      slow.inner.read('fespalier_forms.draft:$actionId:[1]'),
      isNotNull,
      reason: 'left for the next visit',
    );
  });

  testWidgets('exclude names a field the form has', (tester) async {
    await tester.pumpWidget(
      app(MemoryDataStorage(), draft: const FormDraft(exclude: {'pasword'})),
    );
    expect(tester.takeException(), isA<FlutterError>());
  });

  testWidgets('a draft needs an id', (tester) async {
    await tester.pumpWidget(app(MemoryDataStorage(), formId: ''));
    expect(tester.takeException(), isA<AssertionError>());
  });

  testWidgets('a password-like field that is not excluded is warned about', (
    tester,
  ) async {
    final printed = <String?>[];
    final before = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message);
    await tester.pumpWidget(app(MemoryDataStorage(), draft: const FormDraft()));
    debugPrint = before;
    expect(printed.where((m) => m!.contains('`password`')), hasLength(1));
  });

  test(
    'the default storage is the dataCacheStorage, the default scope is null',
    () {
      final storage = MemoryDataStorage();
      final container = ProviderContainer(
        overrides: [dataCacheStorage.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      expect(container.read(formDraftStorage), same(storage));
      expect(container.read(formDraftScope), isNull);
      expect(ProviderContainer().read(formDraftStorage), isNull);
    },
  );

  test('the codecs round-trip, and refuse what they cannot read', () {
    expect(DraftCodec.boolean.decode(DraftCodec.boolean.encode(true)), isTrue);
    expect(DraftCodec.optionalBoolean.decode(null), isNull);
    expect(() => DraftCodec.boolean.decode(null), throwsFormatException);
    expect(() => DraftCodec.boolean.decode('yes'), throwsA(isA<TypeError>()));
    final at = DateTime.utc(2026, 10, 7, 9, 30);
    expect(DraftCodec.dateTime.decode(DraftCodec.dateTime.encode(at)), at);
    expect(DraftCodec.optionalDateTime.encode(null), isNull);
    final moods = DraftCodec.enumOf(Mood.values);
    expect(moods.encode(Mood.loud), 'loud');
    expect(moods.decode('loud'), Mood.loud);
    expect(() => moods.decode('gone'), throwsFormatException);
    final optional = DraftCodec.optionalEnumOf(Mood.values);
    expect(optional.decode(null), isNull);
    expect(optional.decode('calm'), Mood.calm);
  });

  test('the key spells the family key as the URL would', () {
    expect(
      seedKey([
        'x',
        3,
        true,
        null,
        Mood.loud,
        [1, 2],
      ]),
      'fespalier_forms.draft:a#b:["x",3,true,null,"loud",[1,2]]',
    );
    expect(seedKey([], scope: 'u'), 'fespalier_forms.draft:a#b:[]:u');
  });
}

String seedKey(List<Object?> key, {String? scope}) {
  final storage = SpyStorage();
  final container = ProviderContainer(
    overrides: [
      formDraftStorage.overrideWithValue(storage),
      formDraftScope.overrideWithValue(scope),
    ],
  );
  seedFormDraft(container, id: 'a#b', key: key, shape: 's', fields: {'f': 'x'});
  container.dispose();
  return storage.written.first;
}
