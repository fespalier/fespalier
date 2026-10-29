// /inbox: one live change feed (ChangeFeed.live over an event stream) whose topics reload the rows. A
// change reloads its thread only; the server sends no event IDs, so a reopen after a drop is a gap and
// every row reloads once.
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  testWidgets('a change reloads its thread, and no other', (tester) async {
    final live = Live();
    await live.open(tester, '/inbox');

    expect(find.text('2 messages, read 1 time'), findsOneWidget);
    expect(find.text('1 message, read 1 time'), findsOneWidget);
    expect(find.text('0 messages, read 1 time'), findsOneWidget);
    expect(live.logged('sse-open'), ['sse-open #1 inbox']);

    await tapText(tester, 'New message in Billing');

    expect(find.text('3 messages, read 2 times'), findsOneWidget);
    expect(find.text('1 message, read 1 time'), findsOneWidget);
    expect(find.text('0 messages, read 1 time'), findsOneWidget);
  });

  testWidgets('a reopen after a drop is a gap: every thread reloads once', (
    tester,
  ) async {
    final live = Live();
    await live.open(tester, '/inbox');

    await tapText(tester, 'Drop the connection');
    // Nothing moves until the connection opens again.
    expect(find.text('2 messages, read 1 time'), findsOneWidget);

    await live.tick(tester);

    expect(live.logged('sse-open'), ['sse-open #1 inbox', 'sse-open #2 inbox']);
    expect(find.text('2 messages, read 2 times'), findsOneWidget);
    expect(find.text('1 message, read 2 times'), findsOneWidget);
    expect(find.text('0 messages, read 2 times'), findsOneWidget);

    // And after the gap, a change is one thread's again.
    await tapText(tester, 'New message in Returns');
    expect(find.text('1 message, read 3 times'), findsOneWidget);
    expect(find.text('2 messages, read 2 times'), findsOneWidget);
  });
}
