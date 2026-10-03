// A scripted app for the tests of the controller and the panels: answers of its own for each
// service extension, the events it is told to send, and a log of what it was asked.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fespalier_devtools/src/client.dart';
import 'package:fespalier_devtools/src/protocol.dart';
import 'package:flutter/foundation.dart';

/// The route tree `fsp routes --graph json` prints for `examples/features`: the generator's own
/// golden, so the UI is tested on what `fsp` really writes.
Map<String, Object?> featuresTree() => golden('features');

/// A tree golden of one of the examples (`minimal`, `shop`, `features`, `tabs`).
Map<String, Object?> golden(String name) =>
    jsonDecode(
          File('../../cli/tests/golden/$name.devtools.json').readAsStringSync(),
        )
        as Map<String, Object?>;

/// A fixture, written by hand from the records of the protocol.
Map<String, Object?> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync())
        as Map<String, Object?>;

/// What an app of the first release lists in `hello`: no guards, data, actions or open.
const firstFeatures = [
  DevToolsFeatures.navigation,
  DevToolsFeatures.match,
  DevToolsFeatures.navigate,
];

/// What the app lists now (0.8.0: with the holders and the app's own providers).
const allFeatures = [
  ...firstFeatures,
  DevToolsFeatures.guards,
  DevToolsFeatures.data,
  DevToolsFeatures.actions,
  DevToolsFeatures.open,
  DevToolsFeatures.holders,
  DevToolsFeatures.watched,
];

typedef Handler =
    FutureOr<Map<String, Object?>> Function(Map<String, String> params);

/// An app that answers from [handlers], and remembers what it was asked.
class FakeFespalierClient implements FespalierClient {
  /// An app for [snapshot] and [tree]; give [handlers] to answer something else.
  FakeFespalierClient({
    Map<String, Object?>? snapshot,
    Map<String, Object?>? tree,
    bool registered = true,
    bool attached = true,
    int protocol = devToolsProtocol,
    List<String> features = allFeatures,
    Map<String, Handler> handlers = const {},
  }) : _snapshot = snapshot ?? fixture('snapshot_catalog') {
    this.handlers = {
      DevToolsMethods.hello: (_) => HelloRecord(
        protocol: protocol,
        registered: registered,
        attached: attached,
        features: features,
      ).toJson(),
      DevToolsMethods.tree: (_) => {
        'protocol': protocol,
        'tree': tree ?? featuresTree(),
      },
      DevToolsMethods.snapshot: (_) => _snapshot,
      DevToolsMethods.navigate: (_) => {'protocol': protocol, 'ok': true},
      DevToolsMethods.clear: (_) => {'protocol': protocol, 'ok': true},
      DevToolsMethods.invalidate: (_) => {'protocol': protocol, 'ok': true},
      DevToolsMethods.open: (_) => {'protocol': protocol, 'ok': true},
      DevToolsMethods.match: (params) =>
          MatchRecord(location: params['location']!).toJson(),
      ...handlers,
    };
  }

  Map<String, Object?> _snapshot;
  late final Map<String, Handler> handlers;

  /// Every call, in order.
  final calls = <(String method, Map<String, String> params)>[];

  /// The calls of one method.
  List<Map<String, String>> callsTo(String method) => [
    for (final c in calls)
      if (c.$1 == method) c.$2,
  ];

  /// What `snapshot` answers from now on.
  set snapshot(Map<String, Object?> value) => _snapshot = value;

  final _events = StreamController<FespalierEvent>.broadcast();
  final _restarts = _Notifier();

  @override
  final ValueNotifier<bool> connected = ValueNotifier<bool>(true);

  @override
  final ValueNotifier<bool> hasFespalier = ValueNotifier<bool>(true);

  @override
  Stream<FespalierEvent> get events => _events.stream;

  @override
  Listenable get restarts => _restarts;

  /// The app sends an event.
  void emit(String kind, Map<String, Object?> payload) =>
      _events.add((kind: kind, payload: payload));

  /// The app is a new one: a hot restart.
  void restart() => _restarts.fire();

  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, String> params = const {},
  ]) async {
    calls.add((method, params));
    final handler = handlers[method];
    if (handler == null) throw FespalierError('unknown method $method');
    return handler(params);
  }

  @override
  void dispose() {
    unawaited(_events.close());
  }
}

class _Notifier extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// The `navigation` event a router posts for [record].
Map<String, Object?> navigationEvent(int number, NavigationRecord record) => {
  'protocol': devToolsProtocol,
  DevToolsEventPayload.event: number,
  DevToolsEventPayload.record: record.toJson(),
};
