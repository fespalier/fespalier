// /orders/:id: an order followed by server-sent events, through a LiveFeedFamily that a selector
// data.dart returns. A drop waits for the tick, then resumes with Last-Event-ID; a page watched again
// resumes from the ID the feed kept; an order the server refuses is error.dart's.
import 'package:fespalier_stream/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live/wiring.dart';

import 'support.dart';

void main() {
  testWidgets('the order arrives, and follows the server', (tester) async {
    final live = Live();
    await live.open(tester, '/orders/1');

    expect(find.text('Order 1: Ceramic mug'), findsOneWidget);
    expect(find.text('Status: placed'), findsOneWidget);
    expect(statusOf(tester), 'Live');

    await tapText(tester, 'Advance the order');

    expect(find.text('Status: packed'), findsOneWidget);
    expect(find.text('Event 2 from the server'), findsOneWidget);
    expect(live.logged('sse-open'), ['sse-open #1 order-1']);
  });

  testWidgets(
    'a drop waits for the tick, then resumes from the last event it read',
    (tester) async {
      final live = Live();
      await live.open(tester, '/orders/1');
      await tapText(tester, 'Advance the order');

      await tapText(tester, 'Drop the connection');
      expect(statusOf(tester), startsWith('Disconnected (failed)'));
      // What was shown stays: a drop is never an error.
      expect(find.text('Status: packed'), findsOneWidget);

      // The server moves on while the app is away.
      await tapText(tester, 'Advance the order');
      expect(find.text('Status: packed'), findsOneWidget);

      await live.tick(tester);

      expect(statusOf(tester), 'Live, resumed from the last event');
      expect(find.text('Status: shipped'), findsOneWidget);
      expect(live.logged('sse-open'), [
        'sse-open #1 order-1',
        'sse-open #2 order-1 last-event-id=2',
      ]);
    },
  );

  testWidgets('a page watched again resumes from the ID the feed kept', (
    tester,
  ) async {
    final events = FakeEventServer();
    final live = Live(overrides: [liveTransport.overrideWithValue(events)]);
    await live.open(tester, '/orders/2');
    expect(find.text('Connecting to order 2'), findsOneWidget);

    events.current.event(
      '{"id": 2, "item": "Linen apron", "status": "shipped", "seq": 5}',
      id: '5',
    );
    await tester.pumpAndSettle();
    expect(find.text('Status: shipped'), findsOneWidget);
    expect(events.current.header('accept'), 'text/event-stream');

    // Away from the page, nothing watches the feed: it is disposed, and its connection closed.
    await tapText(tester, 'Orders');
    expect(events.current.aborted, isTrue);

    await tapText(tester, 'Order 2: Linen apron');
    expect(events.connections, hasLength(2));
    expect(events.current.lastEventId, '5');
  });

  testWidgets('an order the server does not know is refused, not retried', (
    tester,
  ) async {
    final live = Live();
    await live.open(tester, '/orders/9');

    expect(find.text('The server refused order 9 (404)'), findsOneWidget);
    await live.tick(tester);
    expect(find.text('The server refused order 9 (404)'), findsOneWidget);
  });
}
