// The WHATWG "event stream interpretation", rule by rule, with the body cut into chunks at every
// awkward place.
import 'dart:async';
import 'dart:convert';

import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:flutter_test/flutter_test.dart';

/// What [chunks] decode to, as readable strings.
Future<List<String>> decode(
  List<List<int>> chunks, {
  int maxEventBytes = 1 << 20,
}) async {
  final out = <String>[];
  final items = Stream<List<int>>.fromIterable(
    chunks,
  ).transform(EventStreamDecoder(maxEventBytes: maxEventBytes));
  try {
    await for (final item in items) {
      out.add(switch (item) {
        ServerEvent(:final type, :final data, :final id) =>
          '$type|${jsonEncode(data)}|$id',
        RetryHint(:final delay) => 'retry ${delay.inMilliseconds}',
        Heartbeat() => 'heartbeat',
      });
    }
  } on EventStreamTooLarge catch (e) {
    out.add('too large ${e.limit}');
  }
  return out;
}

Future<List<String>> text(String body) => decode([utf8.encode(body)]);

/// [body] cut after every byte: the hardest chunking there is.
Future<List<String>> bytewise(String body) => decode([
  for (final b in utf8.encode(body)) <int>[b],
]);

void main() {
  test('a message, an event type and an id', () async {
    expect(await text('data: hello\n\n'), ['message|"hello"|null']);
    expect(await text('event: order\nid: 7\ndata: {"id":42}\n\n'), [
      'order|"{\\"id\\":42}"|7',
    ]);
  });

  test('the space after the colon is optional and removed once', () async {
    expect(await text('data:a\n\ndata: b\n\ndata:  c\n\n'), [
      'message|"a"|null',
      'message|"b"|null',
      'message|" c"|null',
    ]);
  });

  test(
    'data lines are joined with a line feed, the last one dropped',
    () async {
      expect(await text('data: one\ndata: two\ndata:\n\n'), [
        'message|"one\\ntwo\\n"|null',
      ]);
    },
  );

  test('a block without data is not dispatched; an empty data is', () async {
    expect(await text('event: x\n\nid: 3\n\ndata\n\n'), ['message|""|3']);
    expect(await text('data:\n\n'), ['message|""|null']);
  });

  test('CR, LF and CRLF end lines, also when split across chunks', () async {
    const body = 'data: a\r\ndata: b\rdata: c\n\r\ndata: d\r\r';
    const want = ['message|"a\\nb\\nc"|null', 'message|"d"|null'];
    expect(await text(body), want);
    expect(await bytewise(body), want);
    // A CR at the end of one chunk and its LF at the start of the next are one line end.
    expect(
      await decode([
        utf8.encode('data: x\r'),
        utf8.encode('\n\r'),
        utf8.encode('\n'),
      ]),
      ['message|"x"|null'],
    );
  });

  test('a code point split across chunks is put back together', () async {
    const body = 'data: Grüße, 東京 🚀\n\n';
    expect(await bytewise(body), ['message|"Grüße, 東京 🚀"|null']);
  });

  test('malformed UTF-8 becomes U+FFFD and decoding goes on', () async {
    expect(
      await decode([
        [...utf8.encode('data: a'), 0xFF, ...utf8.encode('b\n\ndata: c\n\n')],
      ]),
      ['message|"a\uFFFDb"|null', 'message|"c"|null'],
    );
  });

  test('a byte order mark at the start is skipped, once', () async {
    expect(await text('\uFEFFdata: a\n\n'), ['message|"a"|null']);
    expect(await bytewise('\uFEFFdata: a\n\n'), ['message|"a"|null']);
    // Not at the start of the body: a field named "\uFEFFdata", which is ignored.
    expect(await text('data: a\n\n\uFEFFdata: b\n\n'), ['message|"a"|null']);
    // Two at the start: the second one starts a field name.
    expect(await text('\uFEFF\uFEFFdata: a\n\ndata: b\n\n'), [
      'message|"b"|null',
    ]);
  });

  test(
    'the last event ID carries over, an empty id clears it, a NUL is ignored',
    () async {
      expect(
        await text(
          'id: 1\ndata: a\n\n'
          'data: b\n\n'
          'id: 2\u0000\ndata: c\n\n'
          'id\ndata: d\n\n'
          'id: 3\n\ndata: e\n\n',
        ),
        [
          'message|"a"|1',
          'message|"b"|1',
          'message|"c"|1',
          'message|"d"|null',
          'message|"e"|3',
        ],
      );
    },
  );

  test('the event type does not carry over', () async {
    expect(await text('event: x\ndata: a\n\ndata: b\n\n'), [
      'x|"a"|null',
      'message|"b"|null',
    ]);
  });

  test('retry takes ASCII digits only', () async {
    expect(
      await text(
        'retry: 1500\n\nretry: 1.5\n\nretry: -1\n\nretry:\n\nretry: 2s\n\n',
      ),
      ['retry 1500'],
    );
  });

  test('a comment is a heartbeat; unknown fields are ignored', () async {
    expect(await text(': ping\n\nfoo: bar\ndata: a\n\n:\n'), [
      'heartbeat',
      'message|"a"|null',
      'heartbeat',
    ]);
  });

  test('an event with no blank line after it is dropped at the end', () async {
    expect(await text('data: a\n\ndata: b\n'), ['message|"a"|null']);
    expect(await text('data: a\n\ndata: b'), ['message|"a"|null']);
  });

  test(
    'an event larger than maxEventBytes fails the stream and ends it',
    () async {
      expect(
        await decode([utf8.encode('data: 12345\n\n')], maxEventBytes: 12),
        ['message|"12345"|null'],
      );
      expect(
        await decode([
          utf8.encode('data: 12345\n\n'),
          utf8.encode('data: 1234567\n\n'),
          utf8.encode('data: never\n\n'),
        ], maxEventBytes: 12),
        ['message|"12345"|null', 'too large 12'],
      );
      // A line that never ends is bounded too, and the rest of the body is not read.
      final source = StreamController<List<int>>();
      final items = source.stream.transform(
        const EventStreamDecoder(maxEventBytes: 8),
      );
      final seen = <Object>[];
      final done = Completer<void>();
      final sub = items.listen(
        seen.add,
        onError: (Object e) => seen.add(e),
        onDone: done.complete,
      );
      source.add(utf8.encode(': aaaa'));
      source.add(utf8.encode('aaaa'));
      await done.future;
      expect(seen.single, isA<EventStreamTooLarge>());
      expect(source.hasListener, isFalse);
      await sub.cancel();
      await source.close();
    },
  );

  test('pausing the output pauses the body', () async {
    final source = StreamController<List<int>>();
    final sub = source.stream
        .transform(const EventStreamDecoder())
        .listen((_) {});
    sub.pause();
    await pumpEventQueue();
    expect(source.isPaused, isTrue);
    sub.resume();
    await pumpEventQueue();
    expect(source.isPaused, isFalse);
    await sub.cancel();
    expect(source.hasListener, isFalse);
  });

  test('toString prints no data, type or id', () {
    const event = ServerEvent('secret-order-42', type: 'order', id: 'u-7');
    expect(event.toString(), 'ServerEvent');
    expect(
      const RetryHint(Duration(seconds: 2)).toString(),
      'RetryHint(2000 ms)',
    );
    // Two equal-looking events are two events: Riverpod would drop the second if they were ==.
    expect(
      const ServerEvent('a') == ServerEvent(String.fromCharCode(97)),
      isFalse,
    );
  });
}
