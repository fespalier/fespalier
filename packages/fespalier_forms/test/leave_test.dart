// leaveIfClean, the sheet it asks in, and the form as a LeaveSource (since 0.11.0): what the
// generator writes for a folder with a leave.dart, by hand, over a form that has a draft.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/persist.dart';
import 'package:fespalier/testing.dart' show Override;
import 'package:fespalier_forms/fespalier_forms.dart';
import 'package:fespalier_forms/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Fields = ({String nickname});

Fields form() => (nickname: 'ann');

String action(Ref ref, {required Fields input}) => input.nickname;

const actionId = '(account)/nickname/action.dart#action';
const shape = 'nickname:String';

final _action = actionProvider<Fields, String>(
  (Ref ref, Fields input) => action(ref, input: input),
  invalidates: () => const <ProviderListenable<AsyncValue<Object?>>>[],
  site: 'a1_0',
);

/// What `fsp` generates, by hand.
ActionForm<Fields, String, ({ActionTextField<String> nickname})> useForm(
  WidgetRef ref, {
  FormDraft? draft,
}) => useActionForm(
  ref,
  _action,
  data: null,
  initial: form,
  fields: (ActionFormFields<Fields> f) =>
      (nickname: f.text('nickname', (v) => v.nickname, FieldCodec.text)),
  input: (f) => (nickname: f.nickname.value),
  id: actionId,
  key: const [],
  shape: shape,
  draft: draft,
);

/// Set by a test: the draft of the form, or none.
FormDraft? draftOf = const FormDraft();

class EditPage extends HookConsumerWidget {
  const EditPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = useForm(ref, draft: draftOf).fields;
    return Scaffold(
      body: TextField(
        key: const Key('nickname'),
        controller: f.nickname.controller,
      ),
    );
  }
}

/// What each `leave()` returned.
final List<Object?> results = [];

/// Replaces the app's prompt for one test, as `leaveIfClean(ask:)`.
LeavePrompt? ask;

/// What the generated `leave()` of the folder is: `leaveIfClean` and nothing else.
GoRouter makeRouter() => GoRouter(
  routes: [
    GoRoute(
      path: '/',
      pageBuilder: (context, state) => MaterialPage<void>(
        key: state.pageKey,
        child: const Scaffold(body: Text('Home')),
      ),
    ),
    GoRoute(
      path: '/edit',
      onExit: (context, state) =>
          leaveExit(context, state, 'edit/leave.dart', (ref, page) {
            final result = leaveIfClean(context, ref, page, ask: ask);
            results.add(result);
            return result;
          }),
      pageBuilder: (context, state) => MaterialPage<void>(
        key: state.pageKey,
        child: leaveScope(state, const EditPage()),
      ),
    ),
  ],
);

late GoRouter router;
late MemoryDataStorage storage;

Future<ProviderContainer> boot(
  WidgetTester tester, {
  List<Override> overrides = const [],
  FutureOr<Storage<String, String>?>? withStorage,
}) async {
  router = makeRouter();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        formDraftStorage.overrideWithValue(withStorage ?? storage),
        ...overrides,
      ],
      retry: (_, _) => null,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  unawaited(router.push<void>('/edit'));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(EditPage)));
}

Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('nickname')), text);
  await tester.pump();
}

Future<void> goBack(WidgetTester tester) async {
  router.pop();
  await tester.pumpAndSettle();
}

String shownText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

PopScope<Object?> popScope(WidgetTester tester) =>
    tester.widget<PopScope<Object?>>(
      find
          .ancestor(
            of: find.byType(EditPage),
            matching: find.byType(PopScope<Object?>),
          )
          .first,
    );

void main() {
  setUp(() {
    storage = MemoryDataStorage();
    draftOf = const FormDraft();
    results.clear();
    ask = null;
  });

  group('a clean page', () {
    testWidgets('goes at once, with a synchronous true', (tester) async {
      await boot(tester);
      await goBack(tester);
      expect(find.text('Home'), findsOneWidget);
      expect(results, [true]);
      expect(find.text('Discard your changes?'), findsNothing);
    });

    testWidgets('keeps the iOS swipe: the page lets a pop through', (
      tester,
    ) async {
      await boot(tester);
      expect(popScope(tester).canPop, isTrue);
      await type(tester, 'bob');
      expect(popScope(tester).canPop, isFalse);
      await type(tester, 'ann');
      expect(popScope(tester).canPop, isTrue);
    });
  });

  group('the sheet', () {
    testWidgets('asks, and "Keep editing" keeps the page and the text', (
      tester,
    ) async {
      await boot(tester);
      await type(tester, 'bob');
      await goBack(tester);
      expect(find.text('Discard your changes?'), findsOneWidget);
      expect(find.text('Keep editing'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);
      expect(find.text('Keep as draft'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Discard your changes?'), findsNothing);
      expect(find.byType(EditPage), findsOneWidget);
      expect(shownText(tester), 'bob');
      expect(results.single, isA<Future<bool>>());
    });

    testWidgets('dismissing it (the scrim) is "Keep editing"', (tester) async {
      await boot(tester);
      await type(tester, 'bob');
      await goBack(tester);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(EditPage), findsOneWidget);
      expect(find.text('Discard your changes?'), findsNothing);
    });

    testWidgets('"Discard" goes, and leaves no draft behind', (tester) async {
      final container = await boot(tester);
      await type(tester, 'bob');
      await goBack(tester);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(
        await readFormDraft(container, id: actionId, shape: shape),
        isNull,
      );
    });

    testWidgets('"Keep as draft" goes, and the form is found as it was', (
      tester,
    ) async {
      final container = await boot(tester);
      await type(tester, 'bob');
      await goBack(tester);
      await tester.tap(find.text('Keep as draft'));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(await readFormDraft(container, id: actionId, shape: shape), {
        'nickname': 'bob',
      });
      unawaited(router.push<void>('/edit'));
      await tester.pumpAndSettle();
      expect(shownText(tester), 'bob');
    });

    testWidgets('"Keep as draft" waits for a storage that writes later', (
      tester,
    ) async {
      final slow = _LateStorage();
      await boot(tester, withStorage: slow);
      await type(tester, 'bob');
      await goBack(tester);
      await tester.tap(find.text('Keep as draft'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(EditPage), findsOneWidget, reason: 'not written yet');
      slow.gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(slow.inner.read('fespalier_forms.draft:$actionId:[]'), isNotNull);
    });

    testWidgets('a form with no draft cannot keep: two buttons', (
      tester,
    ) async {
      draftOf = null;
      await boot(tester);
      await type(tester, 'bob');
      await goBack(tester);
      expect(find.text('Keep as draft'), findsNothing);
      expect(find.text('Keep editing'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);
    });

    testWidgets('the messages are the app\'s own', (tester) async {
      await boot(
        tester,
        overrides: [
          leavePrompt.overrideWithValue(
            askToLeaveSheet(
              messages: const LeaveSheetMessages(
                title: 'Jeter ?',
                body: 'Pas enregistre.',
                stay: 'Continuer',
                discard: 'Jeter',
                keep: 'Brouillon',
              ),
            ),
          ),
        ],
      );
      await type(tester, 'bob');
      await goBack(tester);
      expect(find.text('Jeter ?'), findsOneWidget);
      expect(find.text('Brouillon'), findsOneWidget);
      await tester.tap(find.text('Continuer'));
      await tester.pumpAndSettle();
      expect(find.byType(EditPage), findsOneWidget);
    });
  });

  group('without a sheet', () {
    for (final (choice, stays) in [
      (LeaveChoice.stay, true),
      (LeaveChoice.discard, false),
      (LeaveChoice.keep, false),
    ]) {
      testWidgets('LeavePrompts.answer(${choice.name}) answers at once', (
        tester,
      ) async {
        final container = await boot(
          tester,
          overrides: [LeavePrompts.answer(choice)],
        );
        await type(tester, 'bob');
        await goBack(tester);
        expect(find.text('Discard your changes?'), findsNothing);
        expect(find.byType(EditPage), stays ? findsOneWidget : findsNothing);
        final draft = await readFormDraft(
          container,
          id: actionId,
          shape: shape,
        );
        expect(draft, choice == LeaveChoice.keep ? {'nickname': 'bob'} : null);
      });
    }

    testWidgets('ask: wins over the app\'s prompt', (tester) async {
      await boot(tester, overrides: [LeavePrompts.answer(LeaveChoice.stay)]);
      ask = (context, page) => LeaveChoice.discard;
      await type(tester, 'bob');
      await goBack(tester);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('a prompt that answers later is waited for', (tester) async {
      final gate = Completer<LeaveChoice>();
      await boot(tester);
      ask = (context, page) => gate.future;
      await type(tester, 'bob');
      await goBack(tester);
      expect(find.byType(EditPage), findsOneWidget);
      gate.complete(LeaveChoice.discard);
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
    });
  });

  group('discard() and keep() on the form', () {
    testWidgets('a discarded form writes nothing when the page goes', (
      tester,
    ) async {
      final spy = _CountingStorage();
      await boot(tester, withStorage: spy);
      await type(tester, 'bob');
      await goBack(tester);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(spy.writes, 0);
    });

    testWidgets('discard drops a restored draft too', (tester) async {
      final container = ProviderContainer(
        overrides: [formDraftStorage.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      await seedFormDraft(
        container,
        id: actionId,
        shape: shape,
        fields: {'nickname': 'saved'},
      );
      await boot(tester);
      expect(shownText(tester), 'saved');
      expect(
        popScope(tester).canPop,
        isFalse,
        reason: 'a restored draft is dirty',
      );
      await goBack(tester);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(
        await readFormDraft(container, id: actionId, shape: shape),
        isNull,
      );
    });

    testWidgets('typing after a discard that did not leave keeps the draft', (
      tester,
    ) async {
      final spy = _CountingStorage();
      await boot(tester, withStorage: spy);
      await type(tester, 'bob');
      // A first ask discards, but the page stays (another `go` took over, say).
      ask = (context, page) {
        page.discard();
        return LeaveChoice.stay;
      };
      await goBack(tester);
      expect(find.byType(EditPage), findsOneWidget);
      ask = null;
      await type(tester, 'carl');
      await goBack(tester);
      await tester.tap(find.text('Keep as draft'));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(spy.written, contains('fespalier_forms.draft:$actionId:[]'));
    });
  });
}

final class _CountingStorage extends Storage<String, String> {
  final MemoryDataStorage inner = MemoryDataStorage();
  int writes = 0;
  final List<String> written = [];

  @override
  PersistedData<String>? read(String key) => inner.read(key);

  @override
  void write(String key, String value, StorageOptions options) {
    writes++;
    written.add(key);
    inner.write(key, value, options);
  }

  @override
  void delete(String key) => inner.delete(key);

  @override
  void deleteOutOfDate() {}
}

final class _LateStorage extends Storage<String, String> {
  final MemoryDataStorage inner = MemoryDataStorage();
  final Completer<void> gate = Completer<void>();

  @override
  PersistedData<String>? read(String key) => inner.read(key);

  @override
  FutureOr<void> write(String key, String value, StorageOptions options) =>
      gate.future.then((_) => inner.write(key, value, options));

  @override
  void delete(String key) => inner.delete(key);

  @override
  void deleteOutOfDate() {}
}
