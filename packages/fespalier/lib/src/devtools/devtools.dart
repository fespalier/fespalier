/// The app side of fespalier's DevTools extension (since 0.7.0): service extensions that answer
/// what DevTools asks, and an event when the router commits a location, a guard answers, a
/// `data.dart` provider changes or an action runs.
///
/// Everything here sits behind [kFespalierDevTools], a `const` that is false in release builds,
/// so the compiler removes it (the generated `app.g.dart` calls the registration under
/// `if (kFespalierDevTools)`, and [traceGuard] and [traceData] are identity functions whose body
/// is that same `if`). In a debug or profile build it costs a listener on the router's delegate
/// and bounded lists of what happened. It never starts a timer, never schedules a frame, never
/// reads a provider, never listens to a `Stream` and never changes what a guard, a provider or
/// an action returns (the very object goes through, and a synchronous one stays synchronous):
/// every path runs inside a `try`, and a bug here is printed once and dropped.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart' show Ref;

import '../navigation_kind.dart';
import '../route_match.dart' show UrlMatch;
import '../segments.dart' show GuardResult;
import '../telemetry.dart'
    show TelemetrySite, telemetryDataTrace, telemetryGuardTrace;
import 'protocol.dart';

/// Whether fespalier's DevTools support is compiled in: false in release builds, and in any
/// build run with `--dart-define=fespalier.devtools=false`.
///
/// `dart.vm.product` is what Flutter's `kReleaseMode` reads. It is read here directly so that
/// the protocol file stays free of Flutter imports.
const bool kFespalierDevTools =
    !bool.fromEnvironment('dart.vm.product') &&
    bool.fromEnvironment('fespalier.devtools', defaultValue: true);

/// How many committed locations the history keeps.
const int _historyLimit = 100;

/// How many guard decisions are kept, and how many are waiting for the next commit.
const int _guardLimit = 200;

/// How many action runs are kept.
const int _actionLimit = 100;

/// How many records of disposed providers are kept (the live ones always are).
const int _disposedLimit = 50;

/// The route tree (`fsp routes --graph json`) as `app.g.dart` embeds it, and how it matches a
/// location: what the generated `mount()` registered.
String Function()? _tree;
UrlMatch? Function(Uri uri)? _matchUrl;

/// The router DevTools reads. Weak: the app owns it, and a disposed one must be collectable.
WeakReference<GoRouter>? _router;

final List<NavigationRecord> _history = [];
int _seq = 0;
int _event = 0;

/// What the router's configuration was at the last commit.
NavSnapshot? _last;

/// Whether the service extensions are registered. `registerExtension` throws a second time, and
/// a name is registered once per isolate, so this outlives [debugDevToolsReset].
bool _extensionsRegistered = false;

/// Whether an error of ours was printed: one line, then the rest are dropped.
bool _reported = false;

/// Registers the app with DevTools, once per `mount()`: how to read the route tree, and how to
/// match a location. The generated `mount()` calls it under `if (kFespalierDevTools)`.
///
/// [tree] is a tear-off of a function that returns the tree, so a hot reload hands DevTools the
/// new one. [matchUrl] is `AppRoutes.matchUrl`.
void devToolsRegister({
  required String Function() tree,
  required UrlMatch? Function(Uri uri) matchUrl,
}) {
  if (!kFespalierDevTools) return;
  try {
    _tree = tree;
    _matchUrl = matchUrl;
    _registerExtensions();
    _post(DevToolsEvents.registered, () => const {});
  } catch (e) {
    _report(e);
  }
}

/// Lets DevTools follow [router]: its location, stack and history. The generated
/// `AppRoutes.router()` calls it. An app that `mount()`s the routes into a `GoRouter` of its own
/// calls it once with that router. The last router attached is the one DevTools shows.
///
/// DevTools holds the router weakly, and what is added to it is one listener on its delegate,
/// which `GoRouter.dispose` drops with the delegate.
void devToolsAttach(GoRouter router) {
  if (!kFespalierDevTools) return;
  try {
    final old = _router?.target;
    if (identical(old, router)) return;
    _detach(old);
    router.routerDelegate.addListener(_committed);
    _router = WeakReference(router);
    _last = null;
    // A router attached after its first location has one already: it is where the history starts.
    _record(router.routerDelegate.currentConfiguration);
    _post(DevToolsEvents.registered, () => const {});
  } catch (e) {
    _report(e);
  }
}

void _detach(GoRouter? router) {
  if (router == null) return;
  try {
    router.routerDelegate.removeListener(_committed);
  } catch (_) {
    // A disposed router's delegate has no listeners left to remove.
  }
}

/// The router's delegate notified its listeners: a configuration was committed.
void _committed() {
  try {
    final router = _router?.target;
    if (router == null) return;
    _record(router.routerDelegate.currentConfiguration);
  } catch (e) {
    _report(e);
  }
}

void _report(Object error) {
  if (_reported) return;
  _reported = true;
  debugPrint('fespalier DevTools: $error (not shown again)');
}

// ---------------------------------------------------------------------------------------------
// What the router did

void _record(RouteMatchList config) {
  if (config.isEmpty && config.error == null) return;
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(config.matches, pushed);
  final active = activeMatches(config, pushed);
  final depth = pushed.length;
  final (:kind, :now) = classifyNavigation(config, _last);
  _last = now;
  final record = NavigationRecord(
    seq: ++_seq,
    at: DateTime.now().millisecondsSinceEpoch,
    kind: kind,
    uri: now.leaf,
    fullPath: active.fullPath,
    depth: depth,
    guards: List.of(_pending),
    error: active.error?.toString(),
  );
  // The decisions made since the last commit are this navigation's: a redirect chain is one.
  _pending.clear();
  _history.add(record);
  if (_history.length > _historyLimit) {
    _history.removeRange(0, _history.length - _historyLimit);
  }
  _post(
    DevToolsEvents.navigation,
    () => {DevToolsEventPayload.record: record.toJson()},
  );
}

/// The frames of [matches], bottom first. [prefix] is the path template above them; the path
/// below the last one is returned.
String _frames(
  List<RouteMatchBase> matches,
  String prefix,
  List<FrameRecord> out,
) {
  var path = prefix;
  for (final m in matches) {
    if (m is ImperativeRouteMatch) {
      final children = <FrameRecord>[];
      _frames(m.matches.matches, '', children);
      out.add(
        FrameRecord(
          type: FrameType.pushed,
          path: m.matches.fullPath,
          location: m.matches.uri.toString(),
          pageKey: m.pageKey.value,
          children: children,
        ),
      );
    } else if (m is ShellRouteMatch) {
      final children = <FrameRecord>[];
      final below = _frames(m.matches, path, children);
      out.add(
        FrameRecord(
          type: FrameType.shell,
          path: path,
          location: m.matchedLocation,
          pageKey: m.pageKey.value,
          children: children,
        ),
      );
      path = below;
    } else if (m is RouteMatch) {
      path = _join(path, m.route.path);
      out.add(
        FrameRecord(
          type: FrameType.page,
          path: path,
          location: m.matchedLocation,
          pageKey: m.pageKey.value,
        ),
      );
    }
  }
  return path;
}

/// go_router's `concatenatePaths`, which it does not export: a child path that starts with `/`
/// starts over.
String _join(String parent, String child) {
  if (child.startsWith('/')) return child;
  if (parent.isEmpty || parent == '/') return '/$child';
  return '$parent/$child';
}

LocationRecord _location(RouteMatchList config) {
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(config.matches, pushed);
  final active = activeMatches(config, pushed);
  UrlMatch? match;
  try {
    match = _matchUrl?.call(active.uri);
  } catch (e) {
    _report(e);
  }
  final extra = active.extra;
  return LocationRecord(
    uri: active.uri.toString(),
    fullPath: active.fullPath,
    pathParameters: active.pathParameters,
    query: active.uri.queryParametersAll,
    extra: extra == null ? null : Shown.of(extra),
    route: match == null ? null : '${match.route.runtimeType}',
    params: match?.params.map((k, v) => MapEntry(k, Shown.of(v))),
    error: active.error?.toString(),
  );
}

SnapshotRecord _snapshot() {
  final config = _router?.target?.routerDelegate.currentConfiguration;
  final placed = config != null && !(config.isEmpty && config.error == null);
  final stack = <FrameRecord>[];
  if (config != null && placed) _frames(config.matches, '', stack);
  return SnapshotRecord(
    event: _event,
    registered: _tree != null,
    attached: _router?.target != null,
    location: config != null && placed ? _location(config) : null,
    stack: stack,
    history: List.of(_history),
    guards: List.of(_guards),
    data: [for (final e in _data.values) e.toRecord()],
    actions: [for (final a in _actions) a.toRecord()],
  );
}

// ---------------------------------------------------------------------------------------------
// What the guards, the data and the actions did

final List<GuardRecord> _guards = [];

/// The `seq`s of the guard decisions since the router last committed a location.
final List<int> _pending = [];

/// Whether the guard whose answer comes next did not run (see [debugMarkGuardSkipped]).
bool _skipped = false;

/// What the generated `redirect:` wraps each guard and `redirect.dart` call in: [result] is what
/// the call returned, and it is what [traceGuard] returns, the very object, so a guard that
/// answered at once still answers at once and a `Future` is still the `Future` go_router awaits.
/// [site] is the guard's key in the tree's `sites` (`g5@6`).
///
/// A guard that throws before it returns never gets here, so it is not shown; go_router gets the
/// error as it always did.
///
/// [telemetry] (since 0.8.0) is the call site as telemetry names it: the generated file passes
/// one `const` for each guard in an app made with `telemetry: true`, and none otherwise, so an
/// app without it never reaches the telemetry code.
@pragma('vm:prefer-inline')
@pragma('dart2js:tryInline')
GuardResult traceGuard(
  GoRouterState state,
  String site,
  GuardResult result, {
  TelemetrySite? telemetry,
}) {
  if (kFespalierDevTools) _traceGuard(state, site, result);
  if (telemetry != null) telemetryGuardTrace(state, site, telemetry, result);
  return result;
}

void _traceGuard(GoRouterState state, String site, GuardResult result) {
  final skipped = _skipped;
  _skipped = false;
  try {
    final seq = ++_seq;
    final at = DateTime.now().millisecondsSinceEpoch;
    final uri = state.uri.toString();
    final fullPath = state.fullPath ?? '';
    GuardRecord record(
      String outcome, {
      String? location,
      bool isAsync = false,
      int ms = 0,
      String? error,
    }) => GuardRecord(
      seq: seq,
      at: at,
      site: site,
      uri: uri,
      fullPath: fullPath,
      result: outcome,
      location: location,
      isAsync: isAsync,
      ms: ms,
      error: error,
    );
    if (skipped) {
      _addGuard(record(GuardOutcome.skipped));
    } else if (result is Future<String?>) {
      final watch = Stopwatch()..start();
      _addGuard(record(GuardOutcome.pending, isAsync: true));
      // Only records. It handles its own errors, so it cannot make an unhandled one, and it
      // leaves the original `Future` to its real consumer.
      unawaited(
        result.then<void>(
          (location) {
            try {
              _settleGuard(
                record(
                  location == null ? GuardOutcome.pass : GuardOutcome.redirect,
                  location: location,
                  isAsync: true,
                  ms: watch.elapsedMilliseconds,
                ),
              );
            } catch (e) {
              _report(e);
            }
          },
          onError: (Object error, StackTrace _) {
            try {
              _settleGuard(
                record(
                  GuardOutcome.error,
                  isAsync: true,
                  ms: watch.elapsedMilliseconds,
                  error: _errorText(error),
                ),
              );
            } catch (e) {
              _report(e);
            }
          },
        ),
      );
    } else {
      _addGuard(
        record(
          result == null ? GuardOutcome.pass : GuardOutcome.redirect,
          location: result,
        ),
      );
    }
  } catch (e) {
    _report(e);
  }
}

void _addGuard(GuardRecord record) {
  _guards.add(record);
  if (_guards.length > _guardLimit) {
    _guards.removeRange(0, _guards.length - _guardLimit);
  }
  _pending.add(record.seq);
  if (_pending.length > _guardLimit) {
    _pending.removeRange(0, _pending.length - _guardLimit);
  }
  _post(
    DevToolsEvents.guard,
    () => {DevToolsEventPayload.record: record.toJson()},
  );
}

/// An asynchronous guard answered: the record of the same `seq` is replaced, and sent again.
void _settleGuard(GuardRecord record) {
  final index = _guards.lastIndexWhere((g) => g.seq == record.seq);
  if (index < 0) return;
  _guards[index] = record;
  _post(
    DevToolsEvents.guard,
    () => {DevToolsEventPayload.record: record.toJson()},
  );
}

/// `guardWithParams` calls this when the route's segments did not parse and the guard did not
/// run: the [traceGuard] around it, which comes next, records `skipped` instead of a pass. Not
/// exported.
void debugMarkGuardSkipped() {
  _skipped = true;
}

String _errorText(Object error) {
  String text;
  try {
    text = '$error';
  } catch (_) {
    text = shownThrew;
  }
  return text.length > shownTextLimit
      ? '${text.substring(0, shownTextLimit)}…'
      : text;
}

/// A user value kept for a tool that may never look at it: text at once for what cannot be
/// held weakly (a number, a string, a boolean, a record), otherwise a weak reference that is
/// turned to text when a snapshot or an event is built. A value that was collected reads
/// `<gone>`.
final class _Held {
  factory _Held(Object? value) {
    if (value == null ||
        value is num ||
        value is String ||
        value is bool ||
        value is Record) {
      return _Held._text(Shown.of(value));
    }
    try {
      return _Held._weak(WeakReference<Object>(value), value.runtimeType);
    } on ArgumentError {
      return _Held._text(Shown.of(value));
    }
  }

  _Held._text(this._text) : _ref = null, _type = null;
  _Held._weak(this._ref, this._type) : _text = null;

  final Shown? _text;
  final WeakReference<Object>? _ref;
  final Type? _type;

  Shown get shown {
    final text = _text;
    if (text != null) return text;
    final target = _ref?.target;
    return target == null ? Shown('$_type', '<gone>') : Shown.of(target);
  }
}

/// One provider of a `data.dart`: a container, a site and a key.
final class _DataEntry {
  _DataEntry(
    this.id,
    this.mapKey,
    this.site,
    this.key,
    this.container,
    this.created,
  ) : updated = created;

  final int id;
  final String mapKey;
  final String site;
  final Shown? key;
  final int container;
  final int created;
  int updated;
  int builds = 0;
  String state = DataState.loading;
  _Held? value;
  String? error;

  /// The `Ref` the last build was given, for `invalidate`.
  WeakReference<Ref>? ref;

  /// Which build this is, so that what a superseded build reports is ignored.
  int generation = 0;

  DataRecord toRecord() => DataRecord(
    id: id,
    site: site,
    key: key,
    container: container,
    state: state,
    builds: builds,
    created: created,
    updated: updated,
    value: value?.shown,
    error: error,
  );
}

final Map<String, _DataEntry> _data = {};
final List<_DataEntry> _disposed = [];
int _dataSeq = 0;
int _containerSeq = 0;
Expando<int> _containerIds = Expando<int>('fespalier containers');

/// What the generated provider of a `data.dart` wraps its body in: [result] is what the body
/// returned (`data()` of the file), and it is what [traceData] returns, the very object, so a
/// value stays a value and a `Future` stays the `Future` Riverpod awaits. [site] is the file's
/// key in the tree's `sites` (`d37`), and [key] the family's key, or null.
///
/// It reads no provider and listens to nothing: a `Future` gets a side `then` that only records
/// how it ended, a `Stream` is not touched, and [ref] gets one `onDispose` callback.
///
/// [telemetry] (since 0.8.0) is the call site as telemetry names it, passed only by an app made
/// with `telemetry: true`.
@pragma('vm:prefer-inline')
@pragma('dart2js:tryInline')
T traceData<T>(
  Ref ref,
  String site,
  Object? key,
  T result, {
  TelemetrySite? telemetry,
}) {
  if (kFespalierDevTools) _traceData(ref, site, key, result);
  if (telemetry != null) {
    telemetryDataTrace(ref, telemetry, key != null, result);
  }
  return result;
}

void _traceData(Ref ref, String site, Object? key, Object? result) {
  try {
    final container = _containerIds[ref.container] ??= ++_containerSeq;
    final shown = key == null ? null : Shown.of(key);
    final mapKey = '$container|$site|${shown?.type}|${shown?.text}';
    final now = DateTime.now().millisecondsSinceEpoch;
    var entry = _data[mapKey];
    if (entry == null) {
      entry = _data[mapKey] = _DataEntry(
        ++_dataSeq,
        mapKey,
        site,
        shown,
        container,
        now,
      );
    } else {
      _disposed.remove(entry);
    }
    final built = entry;
    final generation = ++built.generation;
    built
      ..builds += 1
      ..updated = now
      ..value = null
      ..error = null
      ..ref = WeakReference<Ref>(ref);
    if (result is Future<Object?>) {
      built.state = DataState.loading;
      unawaited(
        result.then<void>(
          (value) {
            try {
              if (built.generation != generation) return;
              built
                ..state = DataState.data
                ..value = _Held(value)
                ..updated = DateTime.now().millisecondsSinceEpoch;
              _postData(built);
            } catch (e) {
              _report(e);
            }
          },
          onError: (Object error, StackTrace _) {
            try {
              if (built.generation != generation) return;
              built
                ..state = DataState.error
                ..error = _errorText(error)
                ..updated = DateTime.now().millisecondsSinceEpoch;
              _postData(built);
            } catch (e) {
              _report(e);
            }
          },
        ),
      );
    } else if (result is Stream<Object?>) {
      built.state = DataState.stream;
    } else {
      built
        ..state = DataState.data
        ..value = _Held(result);
    }
    ref.onDispose(() {
      try {
        if (built.generation != generation ||
            !identical(_data[built.mapKey], built)) {
          return;
        }
        // What the disposed build's `Future` reports when it settles is not news any more.
        built
          ..generation += 1
          ..state = DataState.disposed
          ..updated = DateTime.now().millisecondsSinceEpoch;
        _disposed.add(built);
        while (_disposed.length > _disposedLimit) {
          _data.remove(_disposed.removeAt(0).mapKey);
        }
        _postData(built);
      } catch (e) {
        _report(e);
      }
    });
    _postData(built);
  } catch (e) {
    _report(e);
  }
}

void _postData(_DataEntry entry) => _post(
  DevToolsEvents.data,
  () => {DevToolsEventPayload.record: entry.toRecord().toJson()},
);

/// Forgets the records of disposed providers.
void _forgetDisposed() {
  for (final entry in _disposed) {
    _data.remove(entry.mapKey);
  }
  _disposed.clear();
}

/// One run of an action.
final class _ActionEntry {
  _ActionEntry(this.seq, this.site, this.key, this.input)
    : started = DateTime.now().millisecondsSinceEpoch {
    watch.start();
  }

  final int seq;
  final String site;
  final Shown? key;
  final _Held input;
  final int started;
  final Stopwatch watch = Stopwatch();
  String state = ActionState.running;
  int? ms;
  _Held? result;
  String? error;

  ActionRecord toRecord() => ActionRecord(
    seq: seq,
    site: site,
    key: key,
    input: input.shown,
    state: state,
    started: started,
    ms: ms,
    result: result?.shown,
    error: error,
  );
}

final List<_ActionEntry> _actions = [];

/// An action run starts: `ActionNotifier.call` calls it under `if (kFespalierDevTools)`. Returns
/// the run's number for [traceActionEnd], or null when it is not recorded (no [site]: an action
/// that was not made by the generated file). Not exported.
int? traceActionStart(String? site, Object? key, Object? input) {
  if (site == null) return null;
  try {
    final entry = _ActionEntry(
      ++_seq,
      site,
      key == null ? null : Shown.of(key),
      _Held(input),
    );
    _actions.add(entry);
    if (_actions.length > _actionLimit) {
      _actions.removeRange(0, _actions.length - _actionLimit);
    }
    _postAction(entry);
    return entry.seq;
  } catch (e) {
    _report(e);
    return null;
  }
}

/// The run [seq] (from [traceActionStart]) ended with [result], or, when [failed], with [error].
/// Not exported.
void traceActionEnd(
  int? seq, {
  bool failed = false,
  Object? result,
  Object? error,
}) {
  if (seq == null) return;
  try {
    final index = _actions.lastIndexWhere((a) => a.seq == seq);
    if (index < 0) return;
    final entry = _actions[index];
    entry
      ..ms = entry.watch.elapsedMilliseconds
      ..state = failed ? ActionState.error : ActionState.done;
    if (failed) {
      entry.error = _errorText(error ?? 'unknown error');
    } else {
      entry.result = _Held(result);
    }
    _postAction(entry);
  } catch (e) {
    _report(e);
  }
}

void _postAction(_ActionEntry entry) => _post(
  DevToolsEvents.action,
  () => {DevToolsEventPayload.record: entry.toRecord().toJson()},
);

// ---------------------------------------------------------------------------------------------
// Service extensions and events

/// A failed call: what `ServiceExtensionResponse.error` is made of.
final class _Failure implements Exception {
  _Failure(this.code, this.message);
  final int code;
  final String message;
}

const String _noRouter = 'no fespalier router attached';

void _registerExtensions() {
  if (_extensionsRegistered) return;
  _extensionsRegistered = true;
  for (final method in _handlers.keys) {
    try {
      developer.registerExtension(
        method,
        (name, params) => _respond(name, params),
      );
    } on ArgumentError {
      // Registered already (a hot restart in the same isolate): the handler table is the same.
    }
  }
}

Future<developer.ServiceExtensionResponse> _respond(
  String method,
  Map<String, String> params,
) async {
  try {
    final handler = _handlers[method];
    if (handler == null) {
      throw _Failure(
        developer.ServiceExtensionResponse.extensionError,
        'unknown method $method',
      );
    }
    return developer.ServiceExtensionResponse.result(
      jsonEncode(handler(params)),
    );
  } on _Failure catch (f) {
    return developer.ServiceExtensionResponse.error(f.code, f.message);
  } catch (e) {
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      '$e',
    );
  }
}

typedef _Handler = Map<String, Object?> Function(Map<String, String> params);

final Map<String, _Handler> _handlers = {
  DevToolsMethods.hello: _hello,
  DevToolsMethods.tree: _treeResponse,
  DevToolsMethods.snapshot: (_) => _snapshot().toJson(),
  DevToolsMethods.match: _matchResponse,
  DevToolsMethods.navigate: _navigate,
  DevToolsMethods.clear: _clear,
  DevToolsMethods.invalidate: _invalidate,
  DevToolsMethods.open: _open,
};

Map<String, Object?> _ok() => const {'protocol': devToolsProtocol, 'ok': true};

String _param(Map<String, String> params, String name) {
  final value = params[name];
  if (value == null || value.isEmpty) {
    throw _Failure(
      developer.ServiceExtensionResponse.invalidParams,
      'missing parameter `$name`',
    );
  }
  return value;
}

Map<String, Object?> _hello(Map<String, String> params) => HelloRecord(
  registered: _tree != null,
  attached: _router?.target != null,
  features: const [
    DevToolsFeatures.navigation,
    DevToolsFeatures.match,
    DevToolsFeatures.navigate,
    DevToolsFeatures.guards,
    DevToolsFeatures.data,
    DevToolsFeatures.actions,
    DevToolsFeatures.open,
  ],
).toJson();

Map<String, Object?> _treeResponse(Map<String, String> params) {
  final tree = _tree;
  return {
    'protocol': devToolsProtocol,
    'tree': tree == null ? null : jsonDecode(tree()),
  };
}

Map<String, Object?> _matchResponse(Map<String, String> params) {
  final location = _param(params, 'location');
  final matchUrl = _matchUrl;
  if (matchUrl == null) {
    throw _Failure(
      developer.ServiceExtensionResponse.extensionError,
      _noRouter,
    );
  }
  final match = matchUrl(Uri.parse(location));
  return MatchRecord(
    location: location,
    route: match == null ? null : '${match.route.runtimeType}',
    params: {
      for (final e
          in match?.params.entries ?? const <MapEntry<String, Object?>>[])
        e.key: Shown.of(e.value),
    },
    data: match?.data.length ?? 0,
  ).toJson();
}

Map<String, Object?> _navigate(Map<String, String> params) {
  final mode = _param(params, 'mode');
  if (!NavigateMode.all.contains(mode)) {
    throw _Failure(
      developer.ServiceExtensionResponse.invalidParams,
      'unknown mode `$mode`: one of ${NavigateMode.all.join(', ')}',
    );
  }
  final location = mode == NavigateMode.pop ? '' : _param(params, 'location');
  final router = _router?.target;
  if (router == null) {
    throw _Failure(
      developer.ServiceExtensionResponse.extensionError,
      _noRouter,
    );
  }
  switch (mode) {
    case NavigateMode.go:
      router.go(location);
    case NavigateMode.push:
      unawaited(
        router
            .push<Object?>(location)
            .then<void>((_) {}, onError: (Object _) {}),
      );
    case NavigateMode.replace:
      unawaited(
        router
            .replace<Object?>(location)
            .then<void>((_) {}, onError: (Object _) {}),
      );
    case NavigateMode.pop:
      if (router.canPop()) router.pop();
  }
  return _ok();
}

Map<String, Object?> _clear(Map<String, String> params) {
  final what = _param(params, 'what');
  switch (what) {
    case ClearWhat.history:
      _history.clear();
    case ClearWhat.guards:
      _clearGuards();
    case ClearWhat.actions:
      _actions.clear();
    case ClearWhat.all:
      _history.clear();
      _clearGuards();
      _actions.clear();
      _forgetDisposed();
    default:
      throw _Failure(
        developer.ServiceExtensionResponse.invalidParams,
        'unknown `what` `$what`: one of ${ClearWhat.history}, ${ClearWhat.guards}, '
        '${ClearWhat.actions}, ${ClearWhat.all}',
      );
  }
  return _ok();
}

void _clearGuards() {
  _guards.clear();
  _pending.clear();
}

/// Asks the provider behind the data record `id` to build again: `ref.invalidateSelf()` on the
/// `Ref` its last build was given, which is held weakly and used only when it is still mounted.
Map<String, Object?> _invalidate(Map<String, String> params) {
  final raw = _param(params, 'id');
  final id = int.tryParse(raw);
  if (id == null) {
    throw _Failure(
      developer.ServiceExtensionResponse.invalidParams,
      'parameter `id` is not a number: `$raw`',
    );
  }
  Ref? ref;
  for (final entry in _data.values) {
    if (entry.id == id) ref = entry.ref?.target;
  }
  var ok = false;
  if (ref != null && ref.mounted) {
    ref.invalidateSelf();
    ok = true;
  }
  return {'protocol': devToolsProtocol, 'ok': ok};
}

/// Asks the IDE to open `file` (relative to the app folder, one of the tree's) the way
/// Riverpod's DevTools does: a `navigate` event on the `ToolEvent` stream, with a `package:` URI.
Map<String, Object?> _open(Map<String, String> params) {
  final file = _param(params, 'file');
  final tree = _tree;
  if (tree == null) {
    throw _Failure(
      developer.ServiceExtensionResponse.extensionError,
      'no fespalier app registered',
    );
  }
  final decoded = jsonDecode(tree()) as Map<String, Object?>;
  final files = <String>{};
  _treeFiles(decoded, files);
  if (!files.contains(file)) {
    throw _Failure(
      developer.ServiceExtensionResponse.invalidParams,
      '`$file` is not a file of the route tree',
    );
  }
  final package = decoded['package'];
  final appDir = decoded['appDir'];
  if (package is! String || appDir is! String || !appDir.startsWith('lib/')) {
    throw _Failure(
      developer.ServiceExtensionResponse.extensionError,
      'the app folder is not a folder of a package under lib/',
    );
  }
  final uri = 'package:$package/${appDir.substring(4)}/$file';
  final payload = <String, Object?>{
    'fileUri': uri,
    'line': 1,
    'column': 1,
    'source': 'fespalier.devtools',
  };
  final spy = debugDevToolsToolEvents;
  if (spy != null) {
    spy.add(payload);
  } else {
    developer.postEvent('navigate', payload, stream: 'ToolEvent');
  }
  return _ok();
}

/// Every `file` string in the tree: the routes, the layouts and the sites.
void _treeFiles(Object? node, Set<String> out) {
  if (node is Map<String, Object?>) {
    final file = node['file'];
    if (file is String) out.add(file);
    for (final value in node.values) {
      _treeFiles(value, out);
    }
  } else if (node is List<Object?>) {
    for (final item in node) {
      _treeFiles(item, out);
    }
  }
}

/// Whether anything would receive an event now.
bool get _listening =>
    debugDevToolsEvents != null || developer.extensionStreamHasListener;

/// Posts an event of [kind] when a tool is listening, with `protocol` and `event` added to what
/// [record] makes. The counter counts every event, so a reader that was not connected sees a
/// gap and fetches the snapshot.
void _post(String kind, Map<String, Object?> Function() record) {
  final number = ++_event;
  if (!_listening) return;
  try {
    final payload = <String, Object?>{
      'protocol': devToolsProtocol,
      DevToolsEventPayload.event: number,
      ...record(),
    };
    final spy = debugDevToolsEvents;
    if (spy != null) {
      spy.add((kind, payload));
    } else {
      developer.postEvent(kind, payload);
    }
  } catch (e) {
    _report(e);
  }
}

// ---------------------------------------------------------------------------------------------
// For tests of this package

/// When not null, events are added here instead of being posted, even with no tool listening.
/// For `test/devtools_test.dart`; not exported.
List<(String kind, Map<String, Object?> payload)>? debugDevToolsEvents;

/// When not null, what `open` would post on the `ToolEvent` stream is added here instead. For
/// `test/devtools_test.dart`; not exported.
List<Map<String, Object?>>? debugDevToolsToolEvents;

/// What the service extension [method] answers for [params], decoded; an error is
/// `{'errorCode': <int>, 'errorDetail': <text>}`. The same handler table `registerExtension`
/// wraps. For `test/devtools_test.dart`; not exported.
Future<Map<String, Object?>> debugDevToolsCall(
  String method, [
  Map<String, String> params = const {},
]) async {
  final response = await _respond(method, params);
  if (response.isError()) {
    return {
      'errorCode': response.errorCode,
      'errorDetail': response.errorDetail,
    };
  }
  return jsonDecode(response.result!) as Map<String, Object?>;
}

/// Forgets the registration, the attached router, the history and the counters, but not that
/// the service extensions are registered (a name can be registered once per isolate). For
/// `test/devtools_test.dart`; not exported.
void debugDevToolsReset() {
  _detach(_router?.target);
  _router = null;
  _tree = null;
  _matchUrl = null;
  _history.clear();
  _guards.clear();
  _pending.clear();
  _skipped = false;
  _data.clear();
  _disposed.clear();
  _actions.clear();
  _dataSeq = 0;
  _containerSeq = 0;
  _containerIds = Expando<int>('fespalier containers');
  _seq = 0;
  _event = 0;
  _last = null;
  _reported = false;
}
