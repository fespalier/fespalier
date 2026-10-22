// TransportMemo: the bag one logical request carries across its sends.
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the attribute key is a constant a client can rely on', () {
    expect(TransportMemo.key, 'fespalier.memo');
  });

  test('get answers what was set, typed, and null for the wrong type or '
      'a missing key', () {
    final memo = TransportMemo()
      ..set('a', 1)
      ..set('b', 'text');
    expect(memo.get<int>('a'), 1);
    expect(memo.get<String>('b'), 'text');
    expect(memo.get<String>('a'), isNull, reason: 'an int is not a String');
    expect(memo.get<int>('missing'), isNull);
  });

  test('set replaces, putIfAbsent keeps, remove forgets', () {
    final memo = TransportMemo()..set('a', 1);
    memo.set('a', 2);
    expect(memo.get<int>('a'), 2);
    expect(memo.putIfAbsent('a', 3), 2);
    expect(memo.putIfAbsent('b', 4), 4);
    expect(memo.get<int>('b'), 4);
    memo.remove('a');
    expect(memo.get<int>('a'), isNull);
  });

  test(
    'a request finds its memo in the attributes, and has none without one',
    () {
      final memo = TransportMemo();
      final uri = Uri.parse('https://api.example.com/x');
      final plain = TransportRequest(method: 'GET', uri: uri);
      final carrying = plain.copyWith(
        attributes: <String, Object?>{TransportMemo.key: memo},
      );
      expect(plain.memo, isNull);
      expect(carrying.memo, same(memo));
      expect(
        carrying.copyWith(headers: const {'a': 'b'}).memo,
        same(memo),
        reason: 'copyWith keeps the attributes, so a decorator passes it on',
      );
      expect(
        plain
            .copyWith(attributes: <String, Object?>{TransportMemo.key: 'x'})
            .memo,
        isNull,
        reason: 'only a TransportMemo is one',
      );
    },
  );

  test('toString names no entry: a value can be an error naming a user', () {
    final memo = TransportMemo()..set('secret-key', 'ada@example.com');
    expect(memo.toString(), isNot(contains('ada')));
    expect(memo.toString(), isNot(contains('secret-key')));
  });
}
