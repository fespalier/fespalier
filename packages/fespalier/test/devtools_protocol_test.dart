import 'dart:convert';

import 'package:fespalier/src/devtools/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// `x` written as JSON and read back, as a tool on the other side of the VM service has it.
Map<String, Object?> wire(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  test('the protocol is 1', () {
    expect(devToolsProtocol, 1);
  });

  group('Shown', () {
    test('describes a value by its type and text', () {
      expect(Shown.of(42), const Shown('int', '42'));
      expect(Shown.of('a'), const Shown('String', 'a'));
      expect(Shown.of(null), const Shown('Null', 'null'));
      expect(Shown.of([1, 2]).text, '[1, 2]');
    });

    test('cuts a long text to $shownTextLimit characters and an ellipsis', () {
      final shown = Shown.of('x' * 10000);
      expect(shown.text, '${'x' * shownTextLimit}…');
      expect(Shown.of('y' * shownTextLimit).text, 'y' * shownTextLimit);
    });

    test('says so when toString throws', () {
      expect(Shown.of(_Throws()), const Shown('_Throws', shownThrew));
    });
  });

  group('records round-trip through JSON', () {
    const frame = FrameRecord(
      type: FrameType.shell,
      path: '/products',
      location: '/products',
      pageKey: 'k1',
      children: [
        FrameRecord(
          type: FrameType.page,
          path: '/products/:id',
          location: '/products/2',
          pageKey: '/products/:id',
        ),
        FrameRecord(
          type: FrameType.pushed,
          path: '/cart',
          location: '/cart',
          pageKey: 'k2',
          children: [
            FrameRecord(
              type: FrameType.page,
              path: '/cart',
              location: '/cart',
              pageKey: '/cart',
            ),
          ],
        ),
      ],
    );
    const navigation = NavigationRecord(
      seq: 12,
      at: 1696230000123,
      kind: NavigationKind.push,
      uri: '/products/2?tab=info',
      fullPath: '/products/:id',
      depth: 1,
      error: 'GoException: no routes for location: /x',
    );
    final location = LocationRecord(
      uri: '/products/2?tab=info&tab=more',
      fullPath: '/products/:id',
      pathParameters: const {'id': '2'},
      query: const {
        'tab': ['info', 'more'],
      },
      extra: Shown.of(const [1]),
      route: 'ProductRoute',
      params: const {'id': Shown('int', '2')},
    );

    test('Shown', () {
      const shown = Shown('int', '2');
      expect(Shown.fromJson(wire(shown.toJson())), shown);
    });

    test('FrameRecord, with its children', () {
      final back = FrameRecord.fromJson(wire(frame.toJson()));
      expect(back, frame);
      expect(back.hashCode, frame.hashCode);
      expect(back.children[1].children.single.path, '/cart');
    });

    test('NavigationRecord', () {
      expect(NavigationRecord.fromJson(wire(navigation.toJson())), navigation);
    });

    test('LocationRecord, with and without a route', () {
      final back = LocationRecord.fromJson(wire(location.toJson()));
      expect(back, location);
      expect(back.hashCode, location.hashCode);
      expect(back.query['tab'], ['info', 'more']);
      const none = LocationRecord(
        uri: '/x',
        fullPath: '',
        pathParameters: {},
        query: {},
        error: 'GoException: no routes for location: /x',
      );
      final backNone = LocationRecord.fromJson(wire(none.toJson()));
      expect(backNone, none);
      expect(backNone.route, isNull);
      expect(backNone.params, isNull);
      expect(backNone.extra, isNull);
    });

    test('SnapshotRecord', () {
      final snapshot = SnapshotRecord(
        event: 7,
        registered: true,
        attached: true,
        location: location,
        stack: const [frame],
        history: const [navigation],
      );
      final back = SnapshotRecord.fromJson(wire(snapshot.toJson()));
      expect(back, snapshot);
      expect(back.hashCode, snapshot.hashCode);
      expect(snapshot.toJson()['protocol'], 1);
      const empty = SnapshotRecord(
        event: 0,
        registered: false,
        attached: false,
      );
      expect(SnapshotRecord.fromJson(wire(empty.toJson())), empty);
    });

    test('HelloRecord', () {
      const hello = HelloRecord(
        registered: true,
        attached: false,
        features: [DevToolsFeatures.navigation, DevToolsFeatures.match],
      );
      expect(HelloRecord.fromJson(wire(hello.toJson())), hello);
      expect(hello.toJson()['protocol'], 1);
    });

    test('MatchRecord, with a route and without', () {
      const found = MatchRecord(
        location: '/products/2',
        route: 'ProductRoute',
        params: {'id': Shown('int', '2')},
        data: 2,
      );
      expect(MatchRecord.fromJson(wire(found.toJson())), found);
      const none = MatchRecord(location: '/nowhere');
      expect(none.toJson()['match'], isNull);
      expect(MatchRecord.fromJson(wire(none.toJson())), none);
    });

    test('unequal records are unequal', () {
      expect(
        navigation,
        isNot(
          equals(
            NavigationRecord.fromJson({...navigation.toJson(), 'depth': 2}),
          ),
        ),
      );
    });
  });

  group('forward compatibility', () {
    test('a key a record does not know is ignored', () {
      final json = {
        ...const NavigationRecord(
          seq: 1,
          at: 2,
          kind: NavigationKind.go,
          uri: '/',
          fullPath: '/',
          depth: 0,
        ).toJson(),
        'guards': [40, 41],
        'somethingNew': {'a': 1},
      };
      final record = NavigationRecord.fromJson(wire(json));
      expect(record.seq, 1);
      expect(record.kind, 'go');
    });

    test('a snapshot with lists a later protocol added is read', () {
      final json = {
        ...const SnapshotRecord(
          event: 3,
          registered: true,
          attached: true,
        ).toJson(),
        'guards': <Object?>[
          {'seq': 40},
        ],
        'data': <Object?>[],
        'actions': <Object?>[],
      };
      final snapshot = SnapshotRecord.fromJson(wire(json));
      expect(snapshot.event, 3);
      expect(snapshot.history, isEmpty);
    });

    test('a hello with features this reader has never heard of is read', () {
      final hello = HelloRecord.fromJson({
        'protocol': 1,
        'registered': true,
        'attached': true,
        'features': ['navigation', 'guards', 'open'],
      });
      expect(hello.features, contains('guards'));
    });

    test('a navigation kind it does not know is kept as it is', () {
      final record = NavigationRecord.fromJson({
        'seq': 1,
        'at': 1,
        'kind': 'teleport',
        'uri': '/',
        'fullPath': '/',
        'depth': 0,
      });
      expect(record.kind, 'teleport');
    });
  });

  test(
    'every method is a service extension name, every event is fespalier\'s',
    () {
      for (final method in [
        DevToolsMethods.hello,
        DevToolsMethods.tree,
        DevToolsMethods.snapshot,
        DevToolsMethods.match,
        DevToolsMethods.navigate,
        DevToolsMethods.clear,
      ]) {
        expect(method, startsWith('ext.fespalier.'));
      }
      expect(DevToolsEvents.isFespalier(DevToolsEvents.registered), isTrue);
      expect(DevToolsEvents.isFespalier(DevToolsEvents.navigation), isTrue);
      expect(DevToolsEvents.isFespalier('riverpod:something'), isFalse);
    },
  );
}

class _Throws {
  @override
  String toString() => throw StateError('no');
}
