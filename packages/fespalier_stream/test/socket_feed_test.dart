// The provider pattern docs/streaming.md shows for a WebSocket (since 0.25.0): the feed's builder
// makes the connection, a SocketHandle always reaches the current one, and a feed that rebuilds
// gets a connection of its own. A connection made outside the builder and kept past one build
// fails with the single-use error, not with Dart's "Stream has already been listened to".
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:flutter_test/flutter_test.dart';

final chatUrl = Uri.parse('wss://api.example.com/chat');

/// The room the feed joins: a provider its builder watches.
final class Room extends Notifier<int> {
  @override
  int build() => 1;

  void join(int id) => state = id;
}

void main() {
  late FakeSocketConnector connector;
  late ProviderContainer container;

  setUp(() {
    connector = FakeSocketConnector();
    container = ProviderContainer(overrides: streamTestOverrides());
    addTearDown(container.dispose);
  });

  test(
    'a feed that rebuilds gets a new connection, and the handle follows it',
    () async {
      final chatSocket = Provider<SocketHandle>((ref) => SocketHandle());
      final room = NotifierProvider<Room, int>(Room.new);
      final chat = LiveFeed<SocketMessage>((ref, _) {
        final id = ref.watch(room);
        final connection = SocketConnection(
          connector,
          chatUrl,
          onOpen: (socket) => socket.sendText('join $id'),
          name: 'chat',
        );
        ref.onDispose(ref.watch(chatSocket).attach(connection));
        return connection;
      });

      final latest = container.listen(chat.latest, (_, _) {});
      await pumpEventQueue();
      final handle = container.read(chatSocket);
      expect(handle.isOpen, isTrue);
      handle.send(const SocketText('hello'));
      expect(connector.current.sentTexts, ['join 1', 'hello']);

      connector.current.text('a');
      await pumpEventQueue();
      expect((latest.read().value! as SocketText).text, 'a');

      // Another room: the feed rebuilds, the old connection is closed, the handle is the new one's.
      final first = connector.current;
      container.read(room.notifier).join(2);
      await pumpEventQueue();
      expect(first.closedByClient, isTrue);
      expect(connector.sockets, hasLength(2));
      expect(handle.isOpen, isTrue);
      handle.send(const SocketText('hello again'));
      expect(connector.current.sentTexts, ['join 2', 'hello again']);
      expect(first.sentTexts, ['join 1', 'hello']);
      connector.current.text('b');
      await pumpEventQueue();
      expect(latest.read().hasError, isFalse);
      expect((latest.read().value! as SocketText).text, 'b');

      // Nothing watches the feed: no connection, and the handle says so.
      latest.close();
      await pumpEventQueue();
      expect(handle.connection, isNull);
      expect(() => handle.send(const SocketText('x')), throwsStateError);
    },
  );

  test(
    'a feed that is watched again after a retry is a new connection too',
    () async {
      final chatSocket = Provider<SocketHandle>((ref) => SocketHandle());
      final chat = LiveFeed<SocketMessage>((ref, _) {
        final connection = SocketConnection(connector, chatUrl);
        ref.onDispose(ref.watch(chatSocket).attach(connection));
        return connection;
      });
      var latest = container.listen(chat.latest, (_, _) {});
      await pumpEventQueue();
      // The page that sends holds the handle, whatever the feed does.
      final handle = container.listen(chatSocket, (_, _) {});
      latest.close();
      await pumpEventQueue();
      latest = container.listen(chat.latest, (_, _) {});
      await pumpEventQueue();
      expect(connector.connectCount, 2);
      expect(latest.read().hasError, isFalse);
      expect(handle.read().isOpen, isTrue);
      latest.close();
      handle.close();
    },
  );

  test('a connection kept past its feed fails with the single-use error', () async {
    // The pattern the docs used to show: a provider that outlives the feed holds the connection.
    final chatConnection = Provider<SocketConnection>((ref) {
      final connection = SocketConnection(connector, chatUrl);
      ref.onDispose(connection.close);
      return connection;
    });
    final chat = LiveFeed<SocketMessage>((ref, _) => ref.read(chatConnection));
    final page = container.listen(chatConnection, (_, _) {});
    var latest = container.listen(chat.latest, (_, _) {});
    await pumpEventQueue();
    latest
        .close(); // the tab is left: the feed's build ends and closes the connection
    await pumpEventQueue();
    latest = container.listen(chat.latest, (_, _) {}); // and shown again
    await pumpEventQueue();
    final error = latest.read().error;
    expect(error, isA<StateError>());
    expect(
      (error! as StateError).message,
      allOf(contains('single-use'), contains("feed's builder")),
    );
    expect(connector.connectCount, 1);
    latest.close();
    page.close();
  });
}
