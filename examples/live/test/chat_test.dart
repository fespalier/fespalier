// /chat: a WebSocket held by a LiveFeed, signed in with a single-use ticket fetched through the app's
// transport before every connect, the room joined again on every open. A refused ticket ends it: the
// page says signed out, and nothing tries again until Sign in again.
import 'package:fespalier_stream/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live/wiring.dart';

import 'support.dart';

void main() {
  testWidgets('a ticket, the room, and messages both ways', (tester) async {
    final live = Live();
    await live.open(tester, '/chat');

    expect(find.text('Joined lobby as guest-1'), findsOneWidget);
    expect(statusOf(tester), 'Live');
    expect(live.server.log, ['ticket tk-1', 'ws-open #1 ticket=tk-1']);

    await tester.enterText(find.byType(TextField), 'Hi there');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.text('you: Hi there'), findsOneWidget);

    await tapText(tester, 'Message from the other phone');
    expect(
      find.text('other phone: Hello from the other phone (1)'),
      findsOneWidget,
    );
  });

  testWidgets(
    'a closed socket waits for the tick, then a new ticket and the room again',
    (tester) async {
      final live = Live();
      await live.open(tester, '/chat');

      await tapText(tester, 'Close the socket');
      expect(statusOf(tester), startsWith('Disconnected (ended)'));

      await live.tick(tester);

      expect(statusOf(tester), 'Live');
      expect(live.logged('ticket'), ['ticket tk-1', 'ticket tk-2']);
      expect(live.logged('ws-open'), [
        'ws-open #1 ticket=tk-1',
        'ws-open #2 ticket=tk-2',
      ]);
      // The lines of this connection stay, and onOpen joined the room again.
      expect(find.text('Joined lobby as guest-1'), findsOneWidget);
      expect(find.text('Joined lobby as guest-2'), findsOneWidget);
    },
  );

  testWidgets(
    'a refused ticket signs the chat out: no more tries until Sign in again',
    (tester) async {
      final live = Live();
      await live.open(tester, '/chat');

      // The server refuses tickets from now on, and closes the chat with "your session ended".
      await tapText(tester, 'Refuse tickets');
      expect(statusOf(tester), startsWith('Disconnected (failed)'));
      expect(live.logged('ws-closed'), ['ws-closed #1 code=4401 (server)']);

      await live.tick(tester);
      expect(find.text('You are signed out of the chat'), findsOneWidget);
      expect(find.text('The server refused a ticket (401).'), findsOneWidget);
      expect(live.logged('ticket-refused'), hasLength(1));

      // Signed out: the tick asks for nothing.
      await live.tick(tester);
      await live.tick(tester);
      expect(live.logged('ticket-refused'), hasLength(1));

      await tapText(tester, 'Accept tickets');
      await tapText(tester, 'Sign in again');
      expect(find.text('Joined lobby as guest-2'), findsOneWidget);
      expect(live.logged('ws-open').last, 'ws-open #2 ticket=tk-2');
    },
  );

  testWidgets(
    'over FakeSocketConnector: the ticket in the URL, the join first',
    (tester) async {
      final connector = FakeSocketConnector();
      final live = Live(
        overrides: [liveConnector.overrideWithValue(connector)],
      );
      await live.open(tester, '/chat');

      final socket = connector.current;
      expect(socket.url.path, '/chat');
      expect(socket.url.queryParameters['ticket'], 'tk-1');
      expect(socket.sentTexts, ['{"join":"lobby"}']);

      socket.text('{"type": "message", "from": "guest-9", "text": "Hey"}');
      await tester.pumpAndSettle();
      expect(find.text('guest-9: Hey'), findsOneWidget);

      socket.closeFromPeer(1012);
      await tester.pumpAndSettle();
      expect(statusOf(tester), startsWith('Disconnected (unavailable)'));
    },
  );
}
