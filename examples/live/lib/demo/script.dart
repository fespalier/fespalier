// What both servers serve: the in-process demo (lib/demo/live_server.dart) and tool/server.dart. Pure
// Dart, so `dart run tool/server.dart` can import it without Flutter.

/// An order and the statuses it goes through, one per "advance".
final class ScriptOrder {
  /// An order of [item].
  const ScriptOrder(this.id, this.item);

  /// Its number.
  final int id;

  /// What was ordered.
  final String item;
}

/// The orders both servers know. Any other number is answered 404.
const scriptOrders = <ScriptOrder>[
  ScriptOrder(1, 'Ceramic mug'),
  ScriptOrder(2, 'Linen apron'),
  ScriptOrder(3, 'Cast-iron pan'),
];

/// The statuses an order goes through; the last one stays.
const orderStatuses = <String>['placed', 'packed', 'shipped', 'delivered'];

/// An inbox thread.
final class ScriptThread {
  /// A thread [id] called [title], with [messages] to start with.
  const ScriptThread(this.id, this.title, this.messages);

  /// Its id, in the URL and in each change event.
  final String id;

  /// What the inbox shows.
  final String title;

  /// How many messages it starts with.
  final int messages;
}

/// The inbox both servers serve.
const scriptThreads = <ScriptThread>[
  ScriptThread('t1', 'Billing', 2),
  ScriptThread('t2', 'Shipping', 1),
  ScriptThread('t3', 'Returns', 0),
];

/// The answer to [question], one word at a time: what `POST /ask` streams.
List<String> answerWords(String question) {
  final topic = question.trim().replaceAll(RegExp(r'[?.!]+$'), '');
  return [
    ...'You asked: "$topic". A live answer comes in pieces, each written as soon as the server has it,'
        .split(' '),
    ...'and Stop cancels the request under it, so the server stops writing too.'
        .split(' '),
  ];
}

/// The room the chat joins on every open (`{"join": "lobby"}`).
const chatRoom = 'lobby';

/// How long a ticket is accepted after it was minted.
const ticketLifetime = Duration(seconds: 30);

/// The close code a server uses for "your session ended": what both servers close the chat with when
/// they start refusing tickets.
const sessionEndedCode = 4401;
