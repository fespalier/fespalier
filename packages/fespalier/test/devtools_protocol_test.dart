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

    test('GuardRecord, pending and settled', () {
      const pending = GuardRecord(
        seq: 40,
        at: 1696230000123,
        site: 'g5@6',
        uri: '/admin',
        fullPath: '/admin',
        result: GuardOutcome.pending,
        isAsync: true,
      );
      const redirect = GuardRecord(
        seq: 40,
        at: 1696230000123,
        site: 'g5@6',
        uri: '/admin',
        fullPath: '/admin',
        result: GuardOutcome.redirect,
        location: '/login?from=%2Fadmin',
        isAsync: true,
        ms: 12,
      );
      for (final g in [pending, redirect]) {
        expect(GuardRecord.fromJson(wire(g.toJson())), g);
        expect(GuardRecord.fromJson(wire(g.toJson())).hashCode, g.hashCode);
      }
      expect(redirect.toJson()['async'], isTrue);
      expect(pending, isNot(equals(redirect)));
      const failed = GuardRecord(
        seq: 41,
        at: 1,
        site: 'r32',
        uri: '/x',
        fullPath: '',
        result: GuardOutcome.error,
        error: 'Bad state: no',
      );
      expect(GuardRecord.fromJson(wire(failed.toJson())), failed);
    });

    test('DataRecord, with a key and a value, and without', () {
      const keyed = DataRecord(
        id: 3,
        site: 'd37',
        key: Shown('int', '2'),
        container: 1,
        state: DataState.data,
        builds: 2,
        created: 1696230000000,
        updated: 1696230000500,
        value: Shown('Product', 'Product(2)'),
      );
      expect(DataRecord.fromJson(wire(keyed.toJson())), keyed);
      const bare = DataRecord(
        id: 4,
        site: 'd13',
        container: 2,
        state: DataState.error,
        builds: 1,
        created: 1,
        updated: 2,
        error: 'boom',
      );
      expect(DataRecord.fromJson(wire(bare.toJson())), bare);
      expect(bare.toJson()['key'], isNull);
    });

    test('DataRecord, followed through a view: via, provider, listeners', () {
      const watched = DataRecord(
        id: 5,
        site: 'd8',
        key: Shown('int', '2'),
        container: 1,
        state: DataState.data,
        builds: 0,
        created: 1,
        updated: 2,
        value: Shown('String', 'v'),
        via: DataVia.watch,
        provider: Shown('FutureProvider<String>', 'productProvider(2)'),
      );
      expect(DataRecord.fromJson(wire(watched.toJson())), watched);
      expect(watched.toJson()['via'], 'watch');
      expect(watched.toJson()['listeners'], isNull);
      const built = DataRecord(
        id: 6,
        site: 'd7',
        container: 1,
        state: DataState.data,
        builds: 1,
        created: 1,
        updated: 2,
        listeners: 3,
      );
      final decoded = DataRecord.fromJson(wire(built.toJson()));
      expect(decoded, built);
      expect(decoded.via, DataVia.build);
      expect(decoded.listeners, 3);
    });

    test('a data record of a runtime before 0.8.1 is a built one, with no '
        'listeners', () {
      final record = DataRecord.fromJson({
        'id': 1,
        'site': 'd7',
        'key': null,
        'container': 1,
        'state': 'data',
        'builds': 1,
        'created': 1,
        'updated': 2,
        'value': null,
        'error': null,
      });
      expect(record.via, DataVia.build);
      expect(record.provider, isNull);
      expect(record.listeners, isNull);
    });

    test('HolderRecord and HoldersRecord, found and not', () {
      const view = HolderRecord(kind: HolderKind.view, since: 1791018188000);
      const link = HolderRecord(
        kind: HolderKind.link,
        since: 1791018181000,
        keepFor: 30000,
      );
      expect(HolderRecord.fromJson(wire(view.toJson())), view);
      expect(HolderRecord.fromJson(wire(link.toJson())), link);
      const found = HoldersRecord(
        id: 7,
        found: true,
        alive: true,
        listeners: 3,
        others: 1,
        holders: [view, link],
      );
      expect(found.toJson(), {
        'protocol': 1,
        'id': 7,
        'found': true,
        'alive': true,
        'listeners': 3,
        'others': 1,
        'holders': [
          {'kind': 'view', 'since': 1791018188000, 'keepFor': null},
          {'kind': 'link', 'since': 1791018181000, 'keepFor': 30000},
        ],
      });
      expect(HoldersRecord.fromJson(wire(found.toJson())), found);
      const unknown = HoldersRecord(id: 9, found: false);
      expect(unknown.toJson(), {'protocol': 1, 'id': 9, 'found': false});
      expect(HoldersRecord.fromJson(wire(unknown.toJson())), unknown);
      const app = HoldersRecord(id: 8, found: true, holders: [view]);
      expect(HoldersRecord.fromJson(wire(app.toJson())), app);
      expect(app.toJson()['alive'], isNull);
    });

    test('ActionRecord, running and done', () {
      const running = ActionRecord(
        seq: 9,
        site: 'a37_0',
        key: Shown('int', '2'),
        input: Shown('Refund', 'Refund(5)'),
        state: ActionState.running,
        started: 1696230000000,
      );
      expect(ActionRecord.fromJson(wire(running.toJson())), running);
      const done = ActionRecord(
        seq: 9,
        site: 'a37_0',
        input: Shown('Refund', 'Refund(5)'),
        state: ActionState.done,
        started: 1696230000000,
        ms: 120,
        result: Shown('bool', 'true'),
      );
      expect(ActionRecord.fromJson(wire(done.toJson())), done);
      expect(done.toJson()['ms'], 120);
    });

    test('a snapshot carries the guards, data and actions', () {
      const snapshot = SnapshotRecord(
        event: 9,
        registered: true,
        attached: true,
        guards: [
          GuardRecord(
            seq: 1,
            at: 1,
            site: 'g1@2',
            uri: '/',
            fullPath: '/',
            result: GuardOutcome.pass,
          ),
        ],
        data: [
          DataRecord(
            id: 1,
            site: 'd1',
            container: 1,
            state: DataState.loading,
            builds: 1,
            created: 1,
            updated: 1,
          ),
        ],
        actions: [
          ActionRecord(
            seq: 2,
            site: 'a1_0',
            input: Shown('int', '1'),
            state: ActionState.running,
            started: 1,
          ),
        ],
      );
      expect(SnapshotRecord.fromJson(wire(snapshot.toJson())), snapshot);
    });

    test('a navigation names the guards behind it', () {
      const nav = NavigationRecord(
        seq: 12,
        at: 1,
        kind: NavigationKind.go,
        uri: '/login',
        fullPath: '/login',
        depth: 0,
        guards: [40, 41],
      );
      final back = NavigationRecord.fromJson(wire(nav.toJson()));
      expect(back, nav);
      expect(back.guards, [40, 41]);
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

    test('a record from a runtime before the guards had none of their keys', () {
      // What the first release's runtime sends: no `guards`, `data` or `actions`.
      final snapshot = SnapshotRecord.fromJson({
        'protocol': 1,
        'event': 3,
        'registered': true,
        'attached': true,
        'location': null,
        'stack': <Object?>[],
        'history': [
          {
            'seq': 1,
            'at': 1,
            'kind': 'initial',
            'uri': '/',
            'fullPath': '/',
            'depth': 0,
            'error': null,
          },
        ],
      });
      expect(snapshot.guards, isEmpty);
      expect(snapshot.data, isEmpty);
      expect(snapshot.actions, isEmpty);
      expect(snapshot.history.single.guards, isEmpty);
    });

    test('a guard, data or action record keeps its unknown keys out', () {
      final guard = GuardRecord.fromJson({
        ...const GuardRecord(
          seq: 1,
          at: 1,
          site: 'g1@2',
          uri: '/',
          fullPath: '/',
          result: 'teleported',
        ).toJson(),
        'somethingNew': 1,
      });
      // An outcome it does not know is kept, like a navigation kind.
      expect(guard.result, 'teleported');
    });

    test('a snapshot with lists a later protocol added is read', () {
      final json = {
        ...const SnapshotRecord(
          event: 3,
          registered: true,
          attached: true,
        ).toJson(),
        'timeline': <Object?>[
          {'seq': 40},
        ],
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

    test(
      'a holder of a kind it does not know, and a key it does not, are read',
      () {
        final answer = HoldersRecord.fromJson({
          'protocol': 1,
          'id': 1,
          'found': true,
          'holders': [
            {'kind': 'teleporter', 'since': 1, 'somethingNew': 2},
          ],
          'somethingNew': 3,
        });
        expect(answer.holders.single.kind, 'teleporter');
        expect(answer.alive, isNull);
      },
    );

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
        DevToolsMethods.invalidate,
        DevToolsMethods.open,
        DevToolsMethods.holders,
      ]) {
        expect(method, startsWith('ext.fespalier.'));
      }
      expect(DevToolsEvents.isFespalier(DevToolsEvents.registered), isTrue);
      expect(DevToolsEvents.isFespalier(DevToolsEvents.navigation), isTrue);
      expect(DevToolsEvents.isFespalier(DevToolsEvents.guard), isTrue);
      expect(DevToolsEvents.isFespalier(DevToolsEvents.data), isTrue);
      expect(DevToolsEvents.isFespalier(DevToolsEvents.action), isTrue);
      expect(DevToolsEvents.isFespalier('riverpod:something'), isFalse);
    },
  );
}

class _Throws {
  @override
  String toString() => throw StateError('no');
}
