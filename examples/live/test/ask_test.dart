// /ask: a streaming action (ask/action.dart returns a Stream<String>). The answer grows word by word;
// Stop cancels the request and keeps what came; leaving the page cancels it too; an empty question
// never starts one. The demo server writes a word every 100 ms of the test's clock.
import 'dart:async';

import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live/wiring.dart';

import 'support.dart';

/// A transport that answers [status] with a body that fails when the request is aborted, as a real
/// transport's does once the connection is let go.
final class _RefusingTransport implements HttpTransport {
  _RefusingTransport(this.status);

  final int status;
  var aborted = false;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final body = StreamController<List<int>>();
    unawaited(
      request.abortTrigger?.then((_) {
        aborted = true;
        body.addError(TransportAborted(null, request.uri));
        unawaited(body.close());
      }),
    );
    return TransportResponse(
      statusCode: status,
      headers: const {},
      body: body.stream,
    );
  }
}

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

  testWidgets('a refusal ends the answer, and the page says so', (
    tester,
  ) async {
    final transport = _RefusingTransport(502);
    final live = Live(overrides: [liveTransport.overrideWithValue(transport)]);
    await live.open(tester, '/ask');

    await tester.tap(find.widgetWithText(FilledButton, 'Ask'));
    await tester.pumpAndSettle();

    // The body fails when the request is let go; it is not read, so nothing is left uncaught.
    expect(transport.aborted, isTrue);
    expect(
      _state(tester),
      'The answer stopped: TransportStatusError: HTTP 502',
    );
    expect(find.text('Stop'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Ask'), findsOneWidget);
  });
}
