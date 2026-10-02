/// How the extension talks to the app: the service extensions it calls, and the events it
/// listens to. The UI only knows [FespalierClient]; [VmFespalierClient] is the one that runs in
/// DevTools, built on `package:vm_service` types alone so that it is tested on the VM.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vm_service/vm_service.dart';

import 'protocol.dart';

/// An event of the app: its kind (`fespalier:navigation`) and what it carries.
typedef FespalierEvent = ({String kind, Map<String, Object?> payload});

/// A call the app answered with an error, or could not answer.
final class FespalierError implements Exception {
  /// An error with the app's [message].
  const FespalierError(this.message, {this.code});

  /// What the app said (`missing parameter `location``).
  final String message;

  /// The JSON-RPC code, when there was one: -32602 for a bad parameter, -32000 for an error.
  final int? code;

  @override
  String toString() => message;
}

/// What the extension needs from the app.
abstract interface class FespalierClient {
  /// Calls the service extension [method] with [params], and answers its JSON. Throws a
  /// [FespalierError] when the app answers with an error.
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, String> params = const {},
  ]);

  /// The app's events of kind `fespalier:…`, in order.
  Stream<FespalierEvent> get events;

  /// Notifies when the app is a new one: another isolate (a hot restart) or a new connection.
  /// What was fetched from the old one is stale.
  Listenable get restarts;

  /// Whether DevTools is connected to an app.
  ValueListenable<bool> get connected;

  /// Whether the connected app has fespalier's service extensions, which is to say it uses
  /// fespalier 0.7.0 or later and is not a release build.
  ValueListenable<bool> get hasFespalier;

  /// Lets go of what the client listens to.
  void dispose();
}

/// Calls a service extension on the app's main isolate: DevTools'
/// `serviceManager.callServiceExtensionOnMainIsolate`.
typedef CallServiceExtension =
    Future<Response> Function(String method, {Map<String, dynamic>? args});

/// A [FespalierClient] over the VM service that DevTools holds.
///
/// It is given the pieces of DevTools' `serviceManager` it needs, not the global itself (the
/// app's entry point does that), so a test can give it fakes.
final class VmFespalierClient implements FespalierClient {
  /// A client that calls through [callServiceExtension], reads events from the stream
  /// [extensionEvents] answers (null when there is no VM service), and follows [connected],
  /// [hasFespalier] and the [mainIsolate] (a hot restart is a new one).
  VmFespalierClient({
    required CallServiceExtension callServiceExtension,
    required Stream<Event>? Function() extensionEvents,
    required this.connected,
    required this.hasFespalier,
    required ValueListenable<IsolateRef?> mainIsolate,
  }) : _call = callServiceExtension,
       _extensionEvents = extensionEvents,
       _mainIsolate = mainIsolate {
    _lastIsolate = mainIsolate.value?.id;
    _wasConnected = connected.value;
    connected.addListener(_connectionChanged);
    mainIsolate.addListener(_isolateChanged);
    _subscribe();
  }

  final CallServiceExtension _call;
  final Stream<Event>? Function() _extensionEvents;
  final ValueListenable<IsolateRef?> _mainIsolate;
  final _events = StreamController<FespalierEvent>.broadcast();
  final _restarts = _Restarts();
  StreamSubscription<Event>? _subscription;
  String? _lastIsolate;
  bool _wasConnected = false;

  @override
  final ValueListenable<bool> connected;

  @override
  final ValueListenable<bool> hasFespalier;

  @override
  Stream<FespalierEvent> get events => _events.stream;

  @override
  Listenable get restarts => _restarts;

  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, String> params = const {},
  ]) async {
    try {
      final response = await _call(
        method,
        args: params.isEmpty ? null : params,
      );
      return response.json ?? const {};
    } on RPCError catch (e) {
      throw FespalierError(e.details ?? e.message, code: e.code);
    }
  }

  void _subscribe() {
    unawaited(_subscription?.cancel());
    _subscription = _extensionEvents()?.listen(
      _onEvent,
      onError: (Object _) {},
    );
  }

  void _onEvent(Event event) {
    if (event.kind != EventKind.kExtension) return;
    final kind = event.extensionKind;
    if (kind == null || !DevToolsEvents.isFespalier(kind)) return;
    // Another isolate's events are not the app's.
    final from = event.isolate?.id;
    if (from != null && _lastIsolate != null && from != _lastIsolate) return;
    final data = event.extensionData?.data ?? const <String, dynamic>{};
    _events.add((kind: kind, payload: Map<String, Object?>.of(data)));
  }

  /// A new connection has a new VM service, which has the events.
  void _connectionChanged() {
    final now = connected.value;
    if (now && !_wasConnected) {
      _subscribe();
      _lastIsolate = _mainIsolate.value?.id;
      _restarts.fire();
    }
    _wasConnected = now;
  }

  void _isolateChanged() {
    final id = _mainIsolate.value?.id;
    if (id == null || id == _lastIsolate) return;
    _lastIsolate = id;
    _restarts.fire();
  }

  @override
  void dispose() {
    connected.removeListener(_connectionChanged);
    _mainIsolate.removeListener(_isolateChanged);
    unawaited(_subscription?.cancel());
    unawaited(_events.close());
    _restarts.dispose();
  }
}

class _Restarts extends ChangeNotifier {
  void fire() => notifyListeners();
}
