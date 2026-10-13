// leaveIfClean (since 0.11.0): `(account)/nickname/leave.dart` asks before the form with unsaved
// changes goes, in a bottom sheet; the form registers itself as the page's LeaveSource, so
// nothing in the page says so. A clean form goes at once and keeps the iOS swipe.
import 'dart:async';

import 'package:features/app.g.dart';
import 'package:features/nicknames.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_forms/fespalier_forms.dart';
import 'package:fespalier_forms/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const id = '(account)/nickname/action.dart#action';
const shape = 'nickname:String,age:int?,newsletter:bool';

void main() {
  late ProfileServer server;
  late MemoryDataStorage storage;
  late GoRouter router;

  setUp(() {
    server = ProfileServer();
    storage = MemoryDataStorage();
  });

  /// Opens /profile and pushes /nickname over it in the same tab layout: a page with somewhere to
  /// go back to is the one the iOS swipe works on.
  Future<ProviderContainer> open(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    router = AppRoutes.router(initialLocation: '/profile');
    final container = await pumpRouter(
      tester,
      router,
      overrides: [
        profileServerProvider.overrideWithValue(server),
        formDraftStorage.overrideWithValue(storage),
        ...overrides,
      ],
    );
    unawaited(router.push<void>('/nickname'));
    await tester.pumpAndSettle();
    return container;
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(field('Nickname'), text);
    await tester.pump();
  }

  PopScope<Object?> popScope(WidgetTester tester) =>
      tester.widget<PopScope<Object?>>(
        find
            .ancestor(
              of: field('Nickname'),
              matching: find.byType(PopScope<Object?>),
            )
            .first,
      );

  Future<void> goBack(WidgetTester tester) async {
    router.pop();
    await tester.pumpAndSettle();
  }

  testWidgets('a clean form goes at once, and the iOS swipe is on', (
    tester,
  ) async {
    await open(tester);
    expect(popScope(tester).canPop, isTrue);
    await goBack(tester);
    expect(field('Nickname'), findsNothing);
    expect(find.text('Keep editing'), findsNothing);
  });

  testWidgets('a changed form turns the swipe off, and changing it back on', (
    tester,
  ) async {
    await open(tester);
    await type(tester, 'Bob');
    expect(popScope(tester).canPop, isFalse);
    await type(tester, 'Ann');
    expect(popScope(tester).canPop, isTrue);
  });

  testWidgets('stay: "Keep editing" keeps the page and what was typed', (
    tester,
  ) async {
    await open(tester);
    await type(tester, 'Bob');
    await goBack(tester);
    expect(find.text('Discard your changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(field('Nickname'), findsOneWidget);
    expect(tester.widget<TextField>(field('Nickname')).controller!.text, 'Bob');
  });

  testWidgets('discard: the page goes and nothing is kept', (tester) async {
    final container = await open(tester);
    await type(tester, 'Bob');
    await goBack(tester);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(field('Nickname'), findsNothing);
    expect(await readFormDraft(container, id: id, shape: shape), isNull);

    unawaited(router.push<void>('/nickname'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field('Nickname')).controller!.text, 'Ann');
  });

  testWidgets('keep: the page goes and comes back as it was', (tester) async {
    final container = await open(tester);
    await type(tester, 'Bob');
    await goBack(tester);
    await tester.tap(find.text('Keep as draft'));
    await tester.pumpAndSettle();
    expect(field('Nickname'), findsNothing);
    expect(await readFormDraft(container, id: id, shape: shape), {
      'nickname': 'Bob',
    });

    unawaited(router.push<void>('/nickname'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field('Nickname')).controller!.text, 'Bob');
  });

  testWidgets('a link away asks too, and a saved form does not', (
    tester,
  ) async {
    await open(tester);
    await type(tester, 'Bob');
    router.go('/');
    await tester.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump();
    expect(server.saves, 1);
    router.go('/');
    await tester.pumpAndSettle();
    expect(field('Nickname'), findsNothing);
    expect(find.text('Discard your changes?'), findsNothing);
  });

  testWidgets('LeavePrompts.answer decides without a sheet', (tester) async {
    await open(tester, overrides: [LeavePrompts.answer(LeaveChoice.discard)]);
    await type(tester, 'Bob');
    await goBack(tester);
    expect(find.text('Discard your changes?'), findsNothing);
    expect(field('Nickname'), findsNothing);
  });
}
