import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:fespalier_stream/web_socket.dart';
import 'package:live/demo/script.dart';
import 'package:live/wiring.dart';

/// Who is signed in to the chat: a number that **Sign in again** moves. The chat's feed watches it,
/// so signing in again replaces the connection (and its refusal) with a new one.
final chatSession = NotifierProvider<ChatSession, int>(ChatSession.new);

/// The chat's session.
class ChatSession extends Notifier<int> {
  @override
  int build() => 0;

  /// Signs in again: the chat asks for a new ticket.
  void signIn() => state++;
}

/// How the page sends on the chat: it reaches whichever connection the feed holds now. The feed's
/// builder attaches each connection it makes, since a connection lives and dies with that build.
final chatSocket = Provider<SocketHandle>((ref) => SocketHandle());

/// One line of the chat: a message ([from] who) or a notice ([from] null).
final class ChatLine {
  /// A line.
  const ChatLine(this.from, this.text);

  /// Who wrote it (`you`, `guest-2`, `other phone`), or null for a notice.
  final String? from;

  /// What it says.
  final String text;

  /// [message] as a line, or null for what the page does not show (the server's ping). A text that is
  /// not JSON throws a [FormatException]: [_chatLog] skips and counts it.
  static ChatLine? of(SocketMessage message) {
    if (message is! SocketText) return null;
    final json = jsonDecode(message.text);
    return switch (json) {
      {'type': 'joined', 'room': final String room, 'as': final String name} =>
        ChatLine(null, 'Joined $room as $name'),
      {
        'type': 'message',
        'from': final String from,
        'text': final String text,
      } =>
        ChatLine(from, text),
      _ => null,
    };
  }
}

/// The chat so far: the lines since the feed was built (a reopen keeps them, **Sign in again** starts
/// afresh), the last [ChatLog.keep] of them. No `==`, so each message notifies.
final class ChatLog {
  /// The [lines], oldest first.
  const ChatLog(this.lines);

  /// How many lines are kept.
  static const keep = 50;

  /// The lines, oldest first.
  final List<ChatLine> lines;
}

/// Each message the socket brings, as the whole chat so far. A message that is not JSON is skipped and
/// counted by the [EventCodec] (a `fespalier.stream.decode` span with a telemetry sink), and the chat goes
/// on: one bad message from a server must not end the feed. The codec is made per build, so its counts
/// are this connection's.
StreamTransformer<SocketMessage, ChatLog> _chatLog() =>
    StreamTransformer<SocketMessage, ChatLog>.fromBind((messages) {
      final lines = <ChatLine>[];
      final codec = EventCodec.batch<SocketMessage, ChatLine, ChatLine>((
        message,
      ) {
        final line = ChatLine.of(message);
        return line == null ? const <ChatLine>[] : [line];
      }, (line) => line);
      return codec.bind(messages).map((line) {
        lines.add(line);
        if (lines.length > ChatLog.keep) lines.removeAt(0);
        return ChatLog(List.unmodifiable(lines));
      });
    });

/// The chat: a WebSocket held by a feed, with a single-use ticket fetched through the app's transport
/// before every connect (`POST /ws-ticket`), and the room joined again on every open (`onOpen`).
///
/// The connection is made **here, in the feed's builder**: it is single-use, and the feed closes it when
/// the build ends (nothing watches the chat, or [chatSession] moved). A close or a failure waits for a
/// signal or the tick; the ticket endpoint's 401 ends it with `SocketTicketRefused`, which the page shows
/// as signed out, and nothing opens it again until **Sign in again**.
final chat = LiveFeed<ChatLog>(
  (ref, _) {
    ref.watch(chatSession);
    final origin = ref.watch(liveOrigin);
    final connection = SocketConnection(
      ref.watch(liveConnector),
      chatUrlOf(origin),
      grantor: ticketGrantor(
        ref.watch(liveTransport),
        origin.resolve('ws-ticket'),
      ),
      onOpen: (socket) => socket.sendText(jsonEncode({'join': chatRoom})),
      name: 'chat',
    );
    ref.onDispose(ref.watch(chatSocket).attach(connection));
    return connection.transform(_chatLog());
  },
  rules: LiveRules(
    reconnectOn: [reconnectSignal, appShowSignal],
    idle: liveIdle,
  ),
  name: 'chat',
);
