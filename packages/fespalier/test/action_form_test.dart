// ignore_for_file: prefer_function_declarations_over_variables
// (the generated file writes its route members as closures, so these do too)

import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

/// What `fespalier` generates for an `action.dart` with a `form()`, `validate()` and
/// `optimistic()` is the block under "what fsp would generate"; these tests build it by hand, so a
/// change to the template that this runtime cannot take shows here. Pending writes are held on a
/// `Completer`: no timer, no `runAsync`.

// ---- what the app writes ---------------------------------------------------------------

class Profile {
  const Profile(this.name, this.age);
  final String name;
  final int age;
}

class Server {
  String name = 'ann';
  int age = 30;
  int saves = 0;
  int loads = 0;
  Completer<void>? gate;
  Object? failWith;

  Future<Profile> load(int id) async {
    loads++;
    return Profile(name, age);
  }

  Future<String> save(int id, ({String name, int age}) input) async {
    saves++;
    if (gate case final g?) await g.future;
    if (failWith case final e?) throw e;
    if (input.name == 'taken') {
      throw const FieldErrors({'name': 'That name is taken'});
    }
    if (input.name == 'odd') {
      throw const FieldErrors({
        'nickname': 'Not a field',
      }, message: 'Could not save');
    }
    // The server's own spelling: what the page shows once the data loads again.
    name = input.name.toUpperCase();
    age = input.age;
    return name;
  }
}

final serverProvider = Provider<Server>((ref) => Server());

// data.dart
Future<Profile> data(Ref ref, {required int id}) =>
    ref.read(serverProvider).load(id);

// action.dart
typedef ProfileFields = ({String name, int age});

Future<String> action(
  Ref ref, {
  required int id,
  required ProfileFields input,
}) => ref.read(serverProvider).save(id, input);

ProfileFields form(Profile profile) => (name: profile.name, age: profile.age);

FieldErrors? validate(ProfileFields input) => FieldErrors({
  if (input.name.isEmpty) 'name': 'Give it a name',
  if (input.age < 0) 'age': 'Not negative',
});

Profile optimistic(Profile profile, ProfileFields input) =>
    Profile(input.name, input.age);

// A sync action, its form starts from nothing.
int bumps = 0;
int bump(Ref ref, {required ({int by}) input}) => bumps += input.by;

// ---- what fsp would generate -------------------------------------------------------------

final _data1 = FutureProvider.autoDispose.family(
  (Ref ref, int id) => data(ref, id: id),
);

final _optimistic1 = optimisticLayerFamily((int id) => _data1(id));

final _action1_0 = actionFamily(
  (Ref ref, int id, ProfileFields input) => action(ref, id: id, input: input),
  invalidates: (int id) => <ProviderListenable<AsyncValue<Object?>>>[
    _data1(id),
  ],
  validate: validate,
  optimistic: (int id) => _optimistic1(id).patch(optimistic),
  site: 'a1_0',
);

final _action2_0 = actionProvider(
  (Ref ref, ({int by}) input) => bump(ref, input: input),
  invalidates: () => const <ProviderListenable<AsyncValue<Object?>>>[],
  site: 'a2_0',
);

abstract final class ProfileRoute {
  static final action = _action1_0;
  static final useForm =
      (
        WidgetRef ref, {
        required int id,
        required Profile data,
        ActionFormValidation validation = ActionFormValidation.afterSubmit,
        bool resetOnSuccess = false,
        ActionFormMessages messages = const ActionFormMessages(),
      }) => useActionForm(
        ref,
        action(id),
        data: data,
        initial: () => form(data),
        fields: (ActionFormFields<ProfileFields> f) => (
          name: f.text('name', (v) => v.name, FieldCodec.text),
          age: f.text('age', (v) => v.age, FieldCodec.integer),
        ),
        input: (f) => (name: f.name.value, age: f.age.value),
        validate: validate,
        validation: validation,
        resetOnSuccess: resetOnSuccess,
        messages: messages,
      );
}

abstract final class BumpRoute {
  static final bumpAction = _action2_0;
  static final useBumpForm =
      (WidgetRef ref, {required Object? data, bool resetOnSuccess = false}) =>
          useActionForm(
            ref,
            bumpAction,
            data: data,
            initial: () => (by: 1),
            fields: (ActionFormFields<({int by})> f) =>
                (by: f.text('by', (v) => v.by, FieldCodec.integer)),
            input: (f) => (by: f.by.value),
            resetOnSuccess: resetOnSuccess,
          );
}

// ---- the page ------------------------------------------------------------------------------

ActionForm<
  ProfileFields,
  String,
  ({ActionTextField<String> name, ActionTextField<int> age})
>?
lastForm;

class ProfilePage extends HookConsumerWidget {
  const ProfilePage({
    super.key,
    required this.profile,
    this.validation = ActionFormValidation.afterSubmit,
    this.resetOnSuccess = false,
  });

  final Profile profile;
  final ActionFormValidation validation;
  final bool resetOnSuccess;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = ProfileRoute.useForm(
      ref,
      id: 1,
      data: profile,
      validation: validation,
      resetOnSuccess: resetOnSuccess,
    );
    lastForm = form;
    final f = form.fields;
    return Column(
      children: [
        Text('Hello ${profile.name} (${profile.age})'),
        TextField(
          key: const Key('name'),
          controller: f.name.controller,
          decoration: InputDecoration(errorText: f.name.error),
        ),
        TextField(
          key: const Key('age'),
          controller: f.age.controller,
          decoration: InputDecoration(errorText: f.age.error),
        ),
        if (form.error case final e?) Text('Failed: $e'),
        if (form.isPending) const Text('Saving'),
        TextButton(onPressed: form.onSubmit, child: const Text('Save')),
        TextButton(
          onPressed: form.isDirty ? form.reset : null,
          child: const Text('Reset'),
        ),
      ],
    );
  }
}

Widget app(
  Server server, {
  ActionFormValidation validation = ActionFormValidation.afterSubmit,
  bool resetOnSuccess = false,
}) => ProviderScope(
  overrides: [serverProvider.overrideWithValue(server)],
  retry: (_, _) => null,
  child: MaterialApp(
    home: Material(
      child: DataView(
        watch: (ref) => ref.watch(_data1(1)),
        refresh: (ref) => ref.invalidate(_data1(1)),
        data: (d) => ProfilePage(
          profile: d,
          validation: validation,
          resetOnSuccess: resetOnSuccess,
        ),
        loading: () => const Text('Loading'),
        error: (e, st, retry) => Text('Error $e'),
        optimistic: (ref) => ref.watch(_optimistic1(1)),
      ),
    ),
  ),
);

TextButton button(WidgetTester tester, String label) =>
    tester.widget<TextButton>(find.widgetWithText(TextButton, label));

Future<void> pumpApp(
  WidgetTester tester,
  Server server, {
  ActionFormValidation validation = ActionFormValidation.afterSubmit,
  bool resetOnSuccess = false,
}) async {
  await tester.pumpWidget(
    app(server, validation: validation, resetOnSuccess: resetOnSuccess),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'a form starts from its data and refuses bad fields without running the action',
    (tester) async {
      final server = Server();
      await pumpApp(tester, server);
      expect(find.text('Hello ann (30)'), findsOneWidget);
      expect(lastForm!.isDirty, isFalse);
      expect(lastForm!.isValid, isTrue);
      expect(button(tester, 'Reset').onPressed, isNull);

      await tester.enterText(find.byKey(const Key('age')), 'abc');
      await tester.pump();
      expect(find.text('Enter a whole number'), findsNothing);
      expect(lastForm!.isValid, isFalse);

      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Enter a whole number'), findsOneWidget);
      expect(server.saves, 0);
      expect(lastForm!.state.isLoading, isFalse);
    },
  );

  testWidgets(
    'validate errors show after the first submit, then as fields change',
    (tester) async {
      final server = Server();
      await pumpApp(tester, server);
      await tester.enterText(find.byKey(const Key('name')), '');
      await tester.pump();
      expect(find.text('Give it a name'), findsNothing);

      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Give it a name'), findsOneWidget);
      expect(server.saves, 0);

      await tester.enterText(find.byKey(const Key('name')), 'bob');
      await tester.pump();
      expect(find.text('Give it a name'), findsNothing);
      await tester.enterText(find.byKey(const Key('age')), '-1');
      await tester.pump();
      expect(find.text('Not negative'), findsOneWidget);
    },
  );

  testWidgets(
    "ActionFormValidation.onChange shows a field's errors once it is changed",
    (tester) async {
      final server = Server();
      await pumpApp(tester, server, validation: ActionFormValidation.onChange);
      await tester.enterText(find.byKey(const Key('age')), '-4');
      await tester.pump();
      expect(find.text('Not negative'), findsOneWidget);
      // The name is not changed, and it is still the data's.
      await tester.enterText(find.byKey(const Key('name')), '');
      await tester.pump();
      expect(find.text('Give it a name'), findsOneWidget);
    },
  );

  testWidgets('onSubmit is null while the action runs', (tester) async {
    final server = Server()..gate = Completer<void>();
    await pumpApp(tester, server);
    expect(button(tester, 'Save').onPressed, isNotNull);
    await tester.enterText(find.byKey(const Key('name')), 'bob');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Saving'), findsOneWidget);
    expect(lastForm!.isPending, isTrue);
    expect(lastForm!.onSubmit, isNull);
    expect(button(tester, 'Save').onPressed, isNull);

    server.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Saving'), findsNothing);
    expect(button(tester, 'Save').onPressed, isNotNull);
    expect(server.saves, 1);
  });

  testWidgets(
    'field errors thrown by the action land on their field and clear when it is edited',
    (tester) async {
      final server = Server();
      await pumpApp(tester, server);
      await tester.enterText(find.byKey(const Key('name')), 'taken');
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump();
      expect(find.text('That name is taken'), findsOneWidget);
      expect(find.text('Hello ann (30)'), findsOneWidget);
      expect(find.textContaining('Failed'), findsNothing);
      await tester.enterText(find.byKey(const Key('name')), 'takenx');
      await tester.pump();
      expect(find.text('That name is taken'), findsNothing);
    },
  );

  testWidgets('keys that are no field show in error', (tester) async {
    final server = Server();
    await pumpApp(tester, server);
    await tester.enterText(find.byKey(const Key('name')), 'odd');
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Failed: Could not save\nNot a field'), findsOneWidget);
  });

  testWidgets("reset restores the data's values and idles the action", (
    tester,
  ) async {
    final server = Server()..failWith = StateError('boom');
    await pumpApp(tester, server);
    await tester.enterText(find.byKey(const Key('name')), 'bob');
    await tester.enterText(find.byKey(const Key('age')), '41');
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Failed: Bad state: boom'), findsOneWidget);
    expect(button(tester, 'Reset').onPressed, isNotNull);

    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(find.textContaining('Failed'), findsNothing);
    expect(lastForm!.fields.name.value, 'ann');
    expect(lastForm!.fields.name.controller.text, 'ann');
    expect(lastForm!.fields.age.controller.text, '30');
    expect(lastForm!.isDirty, isFalse);
    expect(lastForm!.state.hasError, isFalse);
    expect(button(tester, 'Reset').onPressed, isNull);
  });

  testWidgets('new data moves the fields the user left alone', (tester) async {
    final server = Server();
    await pumpApp(tester, server);
    await tester.enterText(find.byKey(const Key('name')), 'bob');
    await tester.pump();

    // Somebody else changed the age: the page's data loads again.
    server.age = 40;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProfilePage)),
    );
    container.invalidate(_data1(1));
    await tester.pump();
    await tester.pump();
    expect(find.text('Hello ann (40)'), findsOneWidget);
    expect(lastForm!.fields.age.controller.text, '40');
    expect(lastForm!.fields.age.value, 40);
    expect(lastForm!.fields.age.isDirty, isFalse);
    // The typed name stays, and it is still the user's change.
    expect(lastForm!.fields.name.controller.text, 'bob');
    expect(lastForm!.fields.name.isDirty, isTrue);
  });

  testWidgets("a pending write's optimistic data does not move the fields", (
    tester,
  ) async {
    final server = Server()
      ..gate = Completer<void>()
      ..failWith = StateError('boom');
    await pumpApp(tester, server);
    await tester.enterText(find.byKey(const Key('name')), 'bob');
    await tester.tap(find.text('Save'));
    await tester.pump();
    // The page shows the optimistic guess, a new object: the form keeps what it has.
    expect(find.text('Hello bob (30)'), findsOneWidget);
    expect(lastForm!.fields.name.isDirty, isTrue);

    server.gate!.complete();
    await tester.pump();
    await tester.pump();
    // The rollback gave the data back; the typing is still there.
    expect(find.text('Hello ann (30)'), findsOneWidget);
    expect(lastForm!.fields.name.value, 'bob');
    expect(lastForm!.fields.name.controller.text, 'bob');
    expect(lastForm!.fields.name.isDirty, isTrue);
  });

  testWidgets('a success settles the baseline: the fields are not dirty', (
    tester,
  ) async {
    final server = Server()..gate = Completer<void>();
    await pumpApp(tester, server);
    await tester.enterText(find.byKey(const Key('name')), 'bob');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Hello bob (30)'), findsOneWidget);

    server.gate!.complete();
    final seen = <String>[];
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      seen.add(
        tester.widgetList<Text>(find.textContaining('Hello')).single.data!,
      );
    }
    expect(seen, isNot(contains('Hello ann (30)')));
    expect(seen.last, 'Hello BOB (30)');
    expect(lastForm!.fields.name.value, 'BOB');
    expect(lastForm!.isDirty, isFalse);
  });

  testWidgets('a sync action submits without a Future', (tester) async {
    bumps = 0;
    Object? result;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Material(
            child: HookConsumer(
              builder: (context, ref, _) {
                final form = BumpRoute.useBumpForm(ref, data: null);
                return Column(
                  children: [
                    TextField(controller: form.fields.by.controller),
                    TextButton(
                      onPressed: () => result = form.submit(),
                      child: Text('bumps $bumps'),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '5');
    await tester.tap(find.text('bumps 0'));
    expect(result, 5);
    expect(result, isNot(isA<Future<Object?>>()));
    await tester.pump();
    expect(find.text('bumps 5'), findsOneWidget);
  });

  testWidgets('resetOnSuccess empties the fields', (tester) async {
    bumps = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Material(
            child: HookConsumer(
              builder: (context, ref, _) {
                final form = BumpRoute.useBumpForm(
                  ref,
                  data: null,
                  resetOnSuccess: true,
                );
                return Column(
                  children: [
                    TextField(controller: form.fields.by.controller),
                    TextButton(
                      onPressed: form.onSubmit,
                      child: Text('bumps $bumps'),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '5');
    await tester.tap(find.text('bumps 0'));
    await tester.pump();
    expect(find.text('bumps 5'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '1',
    );
  });

  testWidgets(
    'the form disposes its controllers',
    experimentalLeakTesting: LeakTesting.settings.withTrackedAll(),
    (tester) async {
      await pumpApp(tester, Server());
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('validate runs in the provider, synchronously', () {
    final container = ProviderContainer(
      overrides: [serverProvider.overrideWithValue(Server())],
    );
    addTearDown(container.dispose);
    final sub = container.listen(ProfileRoute.action(1), (_, _) {});
    addTearDown(sub.close);
    expect(
      () => container.read(ProfileRoute.action(1).notifier).call((
        name: '',
        age: 1,
      )),
      throwsA(isA<FieldErrors>()),
    );
    // No loading state in between: the write never started.
    expect(container.read(ProfileRoute.action(1)).hasError, isTrue);
    expect(container.read(ProfileRoute.action(1)).error, isA<FieldErrors>());
    expect(container.read(serverProvider).saves, 0);
  });

  group('FieldCodec', () {
    const messages = ActionFormMessages();

    test(
      'numbers are trimmed, and an empty one is required unless nullable',
      () {
        expect(FieldCodec.integer.parse(' 12 ', messages).value, 12);
        expect(FieldCodec.integer.parse('', messages).error, 'Required');
        expect(
          FieldCodec.integer.parse('1.5', messages).error,
          'Enter a whole number',
        );
        expect(FieldCodec.optionalInteger.parse('', messages).error, isNull);
        expect(FieldCodec.optionalInteger.parse('', messages).value, isNull);
        expect(FieldCodec.decimal.parse('1.5', messages).value, 1.5);
        expect(FieldCodec.decimal.parse('x', messages).error, 'Enter a number');
        expect(FieldCodec.number.parse('7', messages).value, 7);
        expect(FieldCodec.optionalText.parse('', messages).value, isNull);
        expect(FieldCodec.text.parse('', messages).value, '');
      },
    );

    test('FieldErrors reads as its message and pairs', () {
      expect(const FieldErrors({}).isEmpty, isTrue);
      expect(
        const FieldErrors({'a': 'x', 'b': 'y'}, message: 'm').toString(),
        'm; a: x; b: y',
      );
    });
  });
}
