/// The app side of fespalier's DevTools extension (since 0.7.0): service extensions that answer
/// what DevTools asks, and an event when the router commits a location.
///
/// Everything here sits behind [kFespalierDevTools], a `const` that is false in release builds,
/// so the compiler removes it (the generated `app.g.dart` calls these only under
/// `if (kFespalierDevTools)`). In a debug or profile build it costs a listener on the router's
/// delegate and a bounded list of the locations it committed. It never starts a timer, never
/// schedules a frame, never reads a provider and never changes what a navigation does: every
/// path runs inside a `try`, and a bug here is printed once and dropped.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:go_router/go_router.dart';

import '../route_match.dart' show UrlMatch;
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
({int depth, String base, String leaf, String? top})? _last;

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

/// The pushed pages in [matches], oldest first (a pushed page inside a shell is in the shell's
/// matches).
void _pushed(List<RouteMatchBase> matches, List<ImperativeRouteMatch> out) {
  for (final m in matches) {
    if (m is ImperativeRouteMatch) {
      out.add(m);
    } else if (m is ShellRouteMatch) {
      _pushed(m.matches, out);
    }
  }
}

/// Where [config] is: the list of the page on top (what [GoRouterState] of that page reads),
/// which is [config] itself when nothing was pushed.
RouteMatchList _active(
  RouteMatchList config,
  List<ImperativeRouteMatch> pushed,
) => pushed.isEmpty ? config : pushed.last.matches;

void _record(RouteMatchList config) {
  if (config.isEmpty && config.error == null) return;
  final pushed = <ImperativeRouteMatch>[];
  _pushed(config.matches, pushed);
  final active = _active(config, pushed);
  final depth = pushed.length;
  final top = pushed.isEmpty ? null : pushed.last.pageKey.value;
  final base = config.uri.toString();
  final leaf = active.uri.toString();
  final before = _last;
  final String kind;
  if (before == null) {
    kind = NavigationKind.initial;
  } else if (depth > before.depth) {
    kind = NavigationKind.push;
  } else if (depth < before.depth) {
    // Dropping the pushed pages for another location is a `go`, not a pop.
    kind = base == before.base ? NavigationKind.pop : NavigationKind.go;
  } else if (depth > 0 && (top != before.top || leaf != before.leaf)) {
    // `GoRouter.replace` keeps the page's key and changes what it shows.
    kind = NavigationKind.replace;
  } else if (base == before.base && leaf == before.leaf) {
    kind = NavigationKind.refresh;
  } else {
    kind = NavigationKind.go;
  }
  _last = (depth: depth, base: base, leaf: leaf, top: top);
  final record = NavigationRecord(
    seq: ++_seq,
    at: DateTime.now().millisecondsSinceEpoch,
    kind: kind,
    uri: leaf,
    fullPath: active.fullPath,
    depth: depth,
    error: active.error?.toString(),
  );
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
  _pushed(config.matches, pushed);
  final active = _active(config, pushed);
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
  );
}

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
    case ClearWhat.history || ClearWhat.all:
      _history.clear();
    default:
      throw _Failure(
        developer.ServiceExtensionResponse.invalidParams,
        'unknown `what` `$what`: one of ${ClearWhat.history}, ${ClearWhat.all}',
      );
  }
  return _ok();
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
  _seq = 0;
  _event = 0;
  _last = null;
  _reported = false;
}
