/// What the extension knows about the app: fetched when DevTools connects and when the app says
/// something changed. It starts no timer: everything it does is an answer to a call or an event.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'client.dart';
import 'protocol.dart';
import 'tree.dart';

/// Where the extension stands with the app.
enum FespalierStatus {
  /// DevTools is not connected to an app.
  waiting,

  /// The app has no fespalier service extensions: it uses an older fespalier, no fespalier, or
  /// is a release build.
  unsupported,

  /// The app speaks another protocol than this extension.
  mismatch,

  /// fespalier is in the app, but `mount()` has not run, so there is no tree.
  notMounted,

  /// The app has a tree, and no router is attached, so there is no location.
  noRouter,

  /// Everything is there.
  ready,

  /// A call failed.
  failed,
}

/// The state of the extension, and what its UI does to the app.
class FespalierController extends ChangeNotifier {
  /// Follows [client], and loads what the app has as soon as there is something to load.
  FespalierController(this.client) {
    client.connected.addListener(_stateChanged);
    client.hasFespalier.addListener(_stateChanged);
    client.restarts.addListener(_restarted);
    _events = client.events.listen(_onEvent);
    _stateChanged();
  }

  /// The app.
  final FespalierClient client;

  StreamSubscription<FespalierEvent>? _events;
  var _disposed = false;
  var _loading = false;
  var _again = false;
  var _treeStale = true;

  FespalierStatus _status = FespalierStatus.waiting;
  String? _statusDetail;
  HelloRecord? _hello;
  RouteTree? _tree;
  SnapshotRecord? _snapshot;
  String? _actionError;
  MatchRecord? _match;
  String? _matchedLocation;

  /// Where the extension stands.
  FespalierStatus get status => _status;

  /// The protocol the app speaks for [FespalierStatus.mismatch], or the error's text for
  /// [FespalierStatus.failed].
  String? get statusDetail => _statusDetail;

  /// What the app answered to `hello`, once it did.
  HelloRecord? get hello => _hello;

  /// The route tree, once fetched.
  RouteTree? get tree => _tree;

  /// The location, stack and history, as of the last fetch.
  SnapshotRecord? get snapshot => _snapshot;

  /// What went wrong with the last `navigate`, `match` or `clear`, or null.
  String? get actionError => _actionError;

  /// The answer to the last `match`, or null.
  MatchRecord? get match => _match;

  /// The location the last `match` was for.
  String? get matchedLocation => _matchedLocation;

  /// The route the router is at, found in the tree by the class the app's matcher gave the
  /// location, else by the route's path template. Null when there is none.
  RouteNode? get currentRoute {
    final tree = _tree;
    final location = _snapshot?.location;
    if (tree == null || location == null) return null;
    return tree.routeByClass(location.route) ??
        (location.fullPath.isEmpty
            ? null
            : tree.routeByPattern(location.fullPath));
  }

  /// Fetches the app's state again, tree included: what the refresh button does, and what a hot
  /// reload (which changes the tree and says nothing) needs.
  Future<void> refresh() {
    _treeStale = true;
    return _load();
  }

  Future<void> _refreshSnapshot() => _load();

  void _stateChanged() {
    if (_disposed) return;
    if (!client.connected.value) {
      _reset(FespalierStatus.waiting);
    } else if (!client.hasFespalier.value) {
      _reset(FespalierStatus.unsupported);
    } else if (_hello == null) {
      unawaited(refresh());
    }
  }

  void _restarted() {
    if (_disposed) return;
    _reset(FespalierStatus.waiting);
    _stateChanged();
  }

  void _reset(FespalierStatus status) {
    _status = status;
    _statusDetail = null;
    _hello = null;
    _tree = null;
    _snapshot = null;
    _match = null;
    _matchedLocation = null;
    _actionError = null;
    _treeStale = true;
    notifyListeners();
  }

  void _onEvent(FespalierEvent event) {
    if (_disposed) return;
    switch (event.kind) {
      case DevToolsEvents.registered:
        _treeStale = true;
        unawaited(_load());
      case DevToolsEvents.navigation:
        final number = event.payload[DevToolsEventPayload.event];
        final seen = _snapshot?.event;
        // A snapshot that is newer than the event has the event in it.
        if (number is int && seen != null && number <= seen) return;
        unawaited(_refreshSnapshot());
    }
  }

  /// One load at a time: a request that comes in meanwhile asks for another one when this
  /// finishes, so a burst of events costs two loads at most.
  Future<void> _load() async {
    if (_loading) {
      _again = true;
      return;
    }
    _loading = true;
    try {
      do {
        _again = false;
        await _loadOnce();
      } while (_again && !_disposed);
    } finally {
      _loading = false;
    }
  }

  Future<void> _loadOnce() async {
    try {
      final hello = HelloRecord.fromJson(
        await client.call(DevToolsMethods.hello),
      );
      if (_disposed) return;
      _hello = hello;
      if (hello.protocol != devToolsProtocol) {
        _status = FespalierStatus.mismatch;
        _statusDetail = '${hello.protocol}';
        notifyListeners();
        return;
      }
      if (!hello.registered) {
        _status = FespalierStatus.notMounted;
        notifyListeners();
        return;
      }
      final fetchTree = _treeStale || _tree == null;
      final answers = await Future.wait([
        if (fetchTree) client.call(DevToolsMethods.tree),
        client.call(DevToolsMethods.snapshot),
      ]);
      if (_disposed) return;
      if (fetchTree) {
        final json = answers.first['tree'];
        _tree = json == null
            ? null
            : RouteTree.fromJson(json as Map<String, Object?>);
        _treeStale = false;
      }
      _snapshot = SnapshotRecord.fromJson(answers.last);
      _status = _snapshot!.attached
          ? FespalierStatus.ready
          : FespalierStatus.noRouter;
      _statusDetail = null;
    } on Object catch (e) {
      if (_disposed) return;
      _status = FespalierStatus.failed;
      _statusDetail = '$e';
    }
    notifyListeners();
  }

  /// Asks the app's router to go to [location] the way [mode] (a [NavigateMode]) says. [location]
  /// is not used for `pop`. A failure is in [actionError].
  Future<void> navigate(String mode, [String location = '']) => _act(() async {
    await client.call(DevToolsMethods.navigate, {
      'mode': mode,
      if (mode != NavigateMode.pop) 'location': location,
    });
  });

  /// Asks the app which route [location] is. The answer is in [match]; a failure in
  /// [actionError].
  Future<void> matchLocation(String location) => _act(() async {
    final answer = MatchRecord.fromJson(
      await client.call(DevToolsMethods.match, {'location': location}),
    );
    _match = answer;
    _matchedLocation = location;
  });

  /// Empties what the app keeps ([what] is a [ClearWhat]), then fetches the state again.
  Future<void> clear(String what) => _act(() async {
    await client.call(DevToolsMethods.clear, {'what': what});
    await _load();
  });

  Future<void> _act(Future<void> Function() action) async {
    _actionError = null;
    try {
      await action();
    } on Object catch (e) {
      _actionError = '$e';
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    client.connected.removeListener(_stateChanged);
    client.hasFespalier.removeListener(_stateChanged);
    client.restarts.removeListener(_restarted);
    unawaited(_events?.cancel());
    super.dispose();
  }
}
