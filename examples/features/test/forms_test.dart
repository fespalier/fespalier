// A form on an action (`(account)/nickname/`), with validation, errors per field, a pending
// submit, reset, and an optimistic patch that the server's value replaces. A save is held on a
// Completer: no timer, no runAsync.
import 'dart:async';

import 'package:features/app.g.dart';
import 'package:features/nicknames.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_forms/fespalier_forms.dart';
import 'package:fespalier_forms/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProfileServer server;

  Future<ProviderContainer> open(WidgetTester tester) => pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/nickname'),
        overrides: [profileServerProvider.overrideWithValue(server)],
      );

  setUp(() => server = ProfileServer());

  Finder field(String label) => find.widgetWithText(TextField, label);

  FilledButton save(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byType(FilledButton));

  TextButton reset(WidgetTester tester) =>
      tester.widget<TextButton>(find.widgetWithText(TextButton, 'Reset'));

  /// The title, and what it showed on each of the next [n] frames.
  String title(WidgetTester tester) =>
      tester.widget<Text>(find.textContaining('Hello ')).data!;

  Future<List<String>> titles(WidgetTester tester, int n) async {
    final seen = <String>[];
    for (var i = 0; i < n; i++) {
      await tester.pump();
      seen.add(title(tester));
    }
    return seen;
  }

  group('initial values and validation', () {
    testWidgets('the form starts from the profile the page shows', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Hello Ann'), findsOneWidget);
      expect(
          tester.widget<TextField>(field('Nickname')).controller!.text, 'Ann');
      expect(tester.widget<TextField>(field('Age')).controller!.text, '30');
      expect(save(tester).onPressed, isNotNull);
      expect(reset(tester).onPressed, isNull);
    });

    testWidgets('an empty nickname is refused before the server hears of it', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(field('Nickname'), '');
      await tester.pump();
      // Nothing shows until the first submit.
      expect(find.text('Enter a nickname'), findsNothing);
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Enter a nickname'), findsOneWidget);
      expect(server.saves, 0);
      // After that it follows the field.
      await tester.enterText(field('Nickname'), 'Bob');
      await tester.pump();
      expect(find.text('Enter a nickname'), findsNothing);
    });

    testWidgets('text that is not a number is the field\'s error', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(field('Age'), 'abc');
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Enter a whole number'), findsOneWidget);
      expect(server.saves, 0);
    });

    testWidgets('validate() speaks for the age', (tester) async {
      await open(tester);
      await tester.enterText(field('Age'), '9');
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('You must be 13 or older'), findsOneWidget);
      expect(server.saves, 0);
    });
  });

  group('errors from the action', () {
    testWidgets('FieldErrors land under their field and clear on edit', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(field('Nickname'), 'admin');
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump();
      expect(find.text('That nickname is taken'), findsOneWidget);
      expect(server.saves, 1);
      // The page rolled back to what the server has.
      expect(find.text('Hello Ann'), findsOneWidget);

      await tester.enterText(field('Nickname'), 'admin2');
      await tester.pump();
      expect(find.text('That nickname is taken'), findsNothing);
    });
  });

  group('pending, optimistic and reset', () {
    testWidgets(
      'the title shows the typed nickname at once, and the server\'s spelling after, '
      'with no frame of the old one',
      (tester) async {
        server.gate = Completer<void>();
        await open(tester);
        await tester.enterText(field('Nickname'), '  Bob ');
        await tester.tap(find.text('Save'));
        await tester.pump();

        // Pending: the button is disabled, the patch is on the page.
        expect(find.text('Saving...'), findsOneWidget);
        expect(save(tester).onPressed, isNull);
        expect(title(tester), 'Hello   Bob ');

        server.gate!.complete();
        final seen = await titles(tester, 5);
        expect(seen, isNot(contains('Hello Ann')));
        expect(seen.last, 'Hello bob');
        expect(find.text('Saving...'), findsNothing);
        // The fields took the server's spelling, and are not dirty any more.
        expect(
          tester.widget<TextField>(field('Nickname')).controller!.text,
          'bob',
        );
        expect(reset(tester).onPressed, isNull);
        expect(save(tester).onPressed, isNotNull);
      },
    );

    testWidgets('a failure rolls the title back and keeps what was typed', (
      tester,
    ) async {
      server
        ..gate = Completer<void>()
        ..failWith = StateError('offline');
      await open(tester);
      await tester.enterText(field('Nickname'), 'Bob');
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(title(tester), 'Hello Bob');

      server.gate!.complete();
      await tester.pump();
      await tester.pump();
      expect(title(tester), 'Hello Ann');
      expect(find.text('Bad state: offline'), findsOneWidget);
      expect(
        tester.widget<TextField>(field('Nickname')).controller!.text,
        'Bob',
      );
      expect(reset(tester).onPressed, isNotNull);
    });

    testWidgets('reset brings the data\'s values back and clears the error', (
      tester,
    ) async {
      server.failWith = StateError('offline');
      await open(tester);
      await tester.enterText(field('Nickname'), 'Bob');
      await tester.enterText(field('Age'), '41');
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Bad state: offline'), findsOneWidget);

      await tester.tap(find.text('Reset'));
      await tester.pump();
      expect(find.text('Bad state: offline'), findsNothing);
      expect(
          tester.widget<TextField>(field('Nickname')).controller!.text, 'Ann');
      expect(tester.widget<TextField>(field('Age')).controller!.text, '30');
      expect(reset(tester).onPressed, isNull);
    });
  });

  group('new data', () {
    testWidgets('fields the user did not touch follow a reload',
        (tester) async {
      final container = await open(tester);
      await tester.enterText(field('Nickname'), 'Bob');
      await tester.pump();

      // Somebody else saved the age elsewhere: the profile loads again.
      await server.save(nickname: 'Ann', age: 44, newsletter: false);
      container.invalidate(NicknameRoute.data);
      await tester.pump();
      await tester.pump();

      expect(tester.widget<TextField>(field('Age')).controller!.text, '44');
      expect(
        tester.widget<TextField>(field('Nickname')).controller!.text,
        'Bob',
      );
    });
  });

  group('drafts', () {
    // The id and shape the generated `useForm` writes (app.g.dart).
    const id = '(account)/nickname/action.dart#action';
    const shape = 'nickname:String,age:int?,newsletter:bool';

    testWidgets(
        'what was typed is kept when the page is left and put back on return',
        (tester) async {
      final storage = MemoryDataStorage();
      final router = AppRoutes.router(initialLocation: '/nickname');
      final container = await pumpRouter(
        tester,
        router,
        overrides: [
          profileServerProvider.overrideWithValue(server),
          formDraftStorage.overrideWithValue(storage),
        ],
      );
      await tester.enterText(field('Nickname'), 'Bob');
      await tester.enterText(field('Age'), 'abc');
      await tester.pump();

      router.go('/');
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      // The raw text, whatever it is: an age that is no number survives too.
      expect(
        await readFormDraft(container, id: id, shape: shape),
        {'nickname': 'Bob', 'age': 'abc'},
      );

      router.go('/nickname');
      await tester.pumpAndSettle();
      expect(
          tester.widget<TextField>(field('Nickname')).controller!.text, 'Bob');
      expect(tester.widget<TextField>(field('Age')).controller!.text, 'abc');
      // The field nobody changed still follows the data.
      expect(find.text('Hello Ann'), findsOneWidget);
      expect(reset(tester).onPressed, isNotNull);
    });

    testWidgets('a draft that was seeded is restored, a saved form clears it', (
      tester,
    ) async {
      final storage = MemoryDataStorage();
      final container = ProviderContainer(
        overrides: [formDraftStorage.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      await seedFormDraft(
        container,
        id: id,
        shape: shape,
        fields: {'nickname': 'Cy'},
      );
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/nickname'),
        overrides: [
          profileServerProvider.overrideWithValue(server),
          formDraftStorage.overrideWithValue(storage),
        ],
      );
      expect(
          tester.widget<TextField>(field('Nickname')).controller!.text, 'Cy');

      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump();
      expect(server.saves, 1);
      expect(await readFormDraft(container, id: id, shape: shape), isNull);
    });
  });
}
