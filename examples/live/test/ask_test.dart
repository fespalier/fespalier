// /ask: a streaming action (ask/action.dart returns a Stream<String>). The answer grows word by word;
// Stop cancels the request and keeps what came; leaving the page cancels it too; an empty question
// never starts one. The demo server writes a word every 100 ms of the test's clock.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

String _state(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('answer-state'))).data!;

String _answer(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('answer'))).data!;

void main() {
  testWidgets('the answer grows word by word, then is done', (tester) async {
    final live = Live();
    await live.open(tester, '/ask');
    expect(_state(tester), 'The answer comes word by word');

    await tester.tap(find.widgetWithText(FilledButton, 'Ask'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_state(tester), 'Writing: 2 words so far');
    expect(_answer(tester), 'You asked:');
    expect(find.text('Stop'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(_state(tester), startsWith('Done: '));
    expect(_answer(tester), endsWith('stops writing too.'));
    expect(live.logged('ask-'), ['ask-open #1', startsWith('ask-ended #1')]);
  });

  testWidgets('Stop keeps what came, and the server stops writing', (
    tester,
  ) async {
    final live = Live();
    await live.open(tester, '/ask');

    await tester.tap(find.widgetWithText(FilledButton, 'Ask'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Stop'));
    await tester.pump();

    expect(_state(tester), 'Stopped after 3 words');
    expect(_answer(tester), 'You asked: "What');
    expect(live.logged('ask-'), ['ask-open #1', 'ask-closed #1 after 3 words']);

    await tester.pump(const Duration(seconds: 2));
    expect(_answer(tester), 'You asked: "What');
    expect(find.widgetWithText(FilledButton, 'Ask'), findsOneWidget);
  });

  testWidgets('leaving the page cancels the request', (tester) async {
    final live = Live();
    await live.open(tester, '/ask');

    await tester.tap(find.widgetWithText(FilledButton, 'Ask'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Orders'));
    await tester.pumpAndSettle();

    // The page leaves with a transition, and the words that come meanwhile still arrive.
    expect(live.logged('ask-'), [
      'ask-open #1',
      startsWith('ask-closed #1 after '),
    ]);
    await tester.pump(const Duration(seconds: 2));
    expect(live.logged('ask-'), hasLength(2));
  });

  testWidgets('an empty question is refused before anything is sent', (
    tester,
  ) async {
    final live = Live();
    await live.open(tester, '/ask');

    await tester.enterText(find.byType(TextField), '  ');
    await tester.tap(find.widgetWithText(FilledButton, 'Ask'));
    await tester.pumpAndSettle();

    expect(find.text('Type a question first'), findsOneWidget);
    expect(_state(tester), 'Not asked');
    expect(live.logged('ask-'), isEmpty);
  });
}
