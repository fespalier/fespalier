/// The app side of fespalier's DevTools extension (since 0.7.0): service extensions that answer
/// what DevTools asks, and an event when the router commits a location, a guard answers, a
/// `data.dart` provider changes or an action runs.
///
/// Everything here sits behind [kFespalierDevTools], a `const` that is false in release builds,
/// so the compiler removes it (the generated `app.g.dart` calls the registration under
/// `if (kFespalierDevTools)`, and [traceGuard], [traceData] and [watchData] are identity
/// functions whose body is that same `if`). In a debug or profile build it costs a listener on
/// the router's delegate, two callbacks on each provider fespalier builds, and bounded lists of
/// what happened. It never starts a timer, never schedules a frame, never reads a provider (nor
/// adds a listener to one), never listens to a `Stream` and never changes what a guard, a
/// provider or an action returns (the very object goes through, and a synchronous one stays
/// synchronous): every path runs inside a `try`, and a bug here is printed once and dropped.
///
/// Who holds a provider (since 0.8.1): the views, the prefetch handles and the `RouteLink`
/// preloads of fespalier itself are recorded, weakly, and listed when DevTools asks
/// (`ext.fespalier.holders`). Riverpod does not export who else listens to a provider, so for one
/// fespalier built the others are counted (`onAddListener`, `onRemoveListener`), and for one the
/// app owns only what fespalier's own views saw is known.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show BuildContext, Element;
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart'
    show
        AsyncValue,
        AsyncValueExtensions,
        ProviderContainer,
        Ref,
        UncontrolledProviderScope,
        WidgetRef;
import 'package:hooks_riverpod/misc.dart' show ProviderBase, ProviderListenable;

import '../navigation_kind.dart';
import '../route_data.dart' show PrefetchHandle, SectionView;
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

/// What the generated `mount()` gave `devToolsRegister` to list the providers of the `data.dart`
/// files, and what it listed.
Map<Object, String> Function()? _providers;
Map<Object, String>? _providerSites;

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
/// new one. [matchUrl] is `AppRoutes.matchUrl`. [providers] (since 0.8.1) is a tear-off of a
/// function that returns each `data.dart`'s provider (the family object, for one keyed by the
/// URL) by its site; it is called once, when DevTools first needs to know whose provider a
/// prefetch was made for, and is null for an app with no `data.dart`.
void devToolsRegister({
  required String Function() tree,
  required UrlMatch? Function(Uri uri) matchUrl,
  Map<Object, String> Function()? providers,
}) {
  if (!kFespalierDevTools) return;
  try {
    _tree = tree;
    _matchUrl = matchUrl;
    _providers = providers;
    _providerSites = null;
    _untraced = null;
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
  _refreshWatched();
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
/// [telemetry] (since 0.8.1) is the call site as telemetry names it: the generated file passes
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

/// What keeps a provider alive that fespalier knows: a view (by its element), or a prefetch (by
/// its handle). Both are weak, so a holder never keeps what it names from being collected.
final class _Holder {
  _Holder(this.kind, this.since, {this.element, this.handle, this.keepFor});

  final String kind;
  final int since;
  final WeakReference<BuildContext>? element;
  final WeakReference<PrefetchHandle>? handle;
  final int? keepFor;

  /// Whether it holds nothing any more: the view is unmounted (or collected), or the handle is
  /// closed (or collected).
  bool get gone {
    final e = element;
    if (e != null) {
      final context = e.target;
      return context == null || !context.mounted;
    }
    final h = handle?.target;
    return h == null || h.isClosed;
  }

  HolderRecord toRecord() =>
      HolderRecord(kind: kind, since: since, keepFor: keepFor);
}

/// How many holders one record keeps (the dead ones are dropped first).
const int _holderLimit = 100;

/// How many records of the app's own providers may be live before the ones that are gone are
/// looked for (a family keyed by a product id adds one for each product shown).
const int _watchedLimit = 100;

/// One provider of a `data.dart`: a container, a site and a key. [via] says whether fespalier
/// built it (and saw each build) or only watched it for the app.
final class _DataEntry {
  _DataEntry(
    this.id,
    this.mapKey,
    this.site,
    this.key,
    this.container,
    this.created, {
    this.via = DataVia.build,
  }) : updated = created;

  final int id;

  /// A `String` for a provider fespalier built, a `(container, provider or site)` record for one
  /// it watched.
  final Object mapKey;
  final String site;
  final Shown? key;
  final int container;
  final int created;
  final String via;
  int updated;
  int builds = 0;
  String state = DataState.loading;
  _Held? value;
  String? error;

  /// For a built provider: how many listeners it has now.
  int listeners = 0;

  /// For a watched one: the provider as text, and weak references to it and to the container
  /// the view saw it in (for `exists` and `invalidate`), and to the last `AsyncValue` a view got.
  Shown? provider;
  WeakReference<ProviderContainer>? owner;
  WeakReference<Object>? source;
  WeakReference<AsyncValue<Object?>>? lastSeen;

  final List<_Holder> holders = [];

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
    via: via,
    provider: provider,
    listeners: via == DataVia.build
        ? (state == DataState.disposed ? 0 : listeners)
        : null,
  );
}

final Map<Object, _DataEntry> _data = {};
final List<_DataEntry> _disposed = [];
int _dataSeq = 0;
int _containerSeq = 0;
Expando<int> _containerIds = Expando<int>('fespalier containers');

/// The mapKey of the provider fespalier built for [site] and [key] in container number
/// [container].
String _buildKey(int container, String site, Shown? key) =>
    '$container|$site|${key?.type}|${key?.text}';

/// What the generated provider of a `data.dart` wraps its body in: [result] is what the body
/// returned (`data()` of the file), and it is what [traceData] returns, the very object, so a
/// value stays a value and a `Future` stays the `Future` Riverpod awaits. [site] is the file's
/// key in the tree's `sites` (`d37`), and [key] the family's key, or null.
///
/// It reads no provider and listens to nothing: a `Future` gets a side `then` that only records
/// how it ended, a `Stream` is not touched, and [ref] gets an `onDispose` callback and, since
/// 0.8.1, an `onAddListener` and an `onRemoveListener` one, which count the provider's listeners.
///
/// [telemetry] (since 0.8.1) is the call site as telemetry names it, passed only by an app made
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
    final mapKey = _buildKey(container, site, shown);
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
        _trimDisposed();
        _postData(built);
      } catch (e) {
        _report(e);
      }
    });
    // Riverpod drops a build's callbacks when it builds again, and the count is the entry's, so
    // it carries over an invalidation: the listeners are the same ones.
    ref.onAddListener(() {
      try {
        built.listeners += 1;
        _postData(built);
      } catch (e) {
        _report(e);
      }
    });
    ref.onRemoveListener(() {
      try {
        if (built.listeners > 0) built.listeners -= 1;
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

/// Drops the oldest records of disposed providers beyond the limit.
void _trimDisposed() {
  while (_disposed.length > _disposedLimit) {
    _data.remove(_disposed.removeAt(0).mapKey);
  }
}

/// Forgets the records of disposed providers.
void _forgetDisposed() {
  for (final entry in _disposed) {
    _data.remove(entry.mapKey);
  }
  _disposed.clear();
}

// ---------------------------------------------------------------------------------------------
// Who holds a provider (since 0.8.1)

/// What the generated `DataView` and `SectionView` watch their data with: `ref.watch(provider)`,
/// returned as it is, so a value that is there stays there (no `Future`, no microtask). [site] is
/// the `data.dart`'s key in the tree's `sites` (`d37`).
///
/// In a debug or profile build it also notes that this view holds [provider] and, for a provider
/// fespalier did not build (the app's own, which a `data.dart` returned or selected), the state
/// the view got. It adds no listener and reads nothing else; in release it is `ref.watch`.
@pragma('vm:prefer-inline')
@pragma('dart2js:tryInline')
AsyncValue<T> watchData<T>(
  WidgetRef ref,
  String site,
  ProviderListenable<AsyncValue<T>> provider,
) {
  final value = ref.watch(provider);
  if (kFespalierDevTools) _traceWatch(ref, site, provider, value);
  return value;
}

/// What one view saw last: when it is the same again, there is nothing to record.
final class _Seen {
  _Seen(this.provider, this.value, this.entry);
  final Object provider;
  final Object? value;
  final _DataEntry? entry;
}

Expando<_Seen> _seen = Expando<_Seen>('fespalier views');

/// The families of the providers the views watched, by site: what `devToolsRegister`'s providers
/// do not list (a selector with parameters is a closure).
final Map<Object, String> _seenSites = {};

/// Prefetches made before any view watched the provider, by container and provider (or site):
/// attached to the record when the view first watches.
final Map<Object, List<_Holder>> _loose = {};

/// Whose handle a prefetch is: `devToolsAs` changes it around a `RouteLink`'s preload.
String _holderKind = HolderKind.prefetch;

/// The sites of the `data.dart` files that return or select a provider of their own.
Set<String>? _untraced;

Set<String> get _untracedSites {
  final known = _untraced;
  if (known != null) return known;
  final tree = _tree;
  if (tree == null) return const {};
  final out = <String>{};
  final decoded = jsonDecode(tree());
  final sites = decoded is Map<String, Object?> ? decoded['sites'] : null;
  if (sites is Map<String, Object?>) {
    for (final e in sites.entries) {
      final site = e.value;
      if (site is Map<String, Object?> &&
          site['kind'] == 'data' &&
          site['traced'] == false) {
        out.add(e.key);
      }
    }
  }
  return _untraced = out;
}

/// The site of the `data.dart` whose provider (or family) [provider] is, when known.
String? _siteOf(Object provider) {
  final key = provider is ProviderBase<Object?>
      ? (provider.from ?? provider)
      : provider;
  final sites = _providerSites ??= _providers?.call() ?? const {};
  return sites[key] ?? _seenSites[key];
}

/// The containers a view sees, the nearest first: each `ProviderScope` above [context]. Riverpod
/// does not export a container's parent, so they are found from the widget tree.
List<ProviderContainer> _containersAbove(BuildContext context) {
  final out = <ProviderContainer>[];
  context.visitAncestorElements((Element e) {
    final widget = e.widget;
    if (widget is UncontrolledProviderScope) out.add(widget.container);
    return true;
  });
  return out;
}

/// The record of the provider fespalier built for [site] and [argument], in one of
/// [containers] (nearest first): Riverpod mounts an unscoped provider in the root, even when a
/// scope below it read it.
_DataEntry? _findBuild(
  List<ProviderContainer> containers,
  String site,
  Object? argument,
) {
  final key = argument == null ? null : Shown.of(argument);
  for (final c in containers) {
    final id = _containerIds[c];
    if (id == null) continue;
    final entry = _data[_buildKey(id, site, key)];
    if (entry != null) return entry;
  }
  return null;
}

/// Adds [holder] to [entry], dropping the holders that are gone (and the one of the same view).
void _hold(_DataEntry entry, _Holder holder) {
  final context = holder.element?.target;
  entry.holders.removeWhere(
    (h) => h.gone || (context != null && h.element?.target == context),
  );
  entry.holders.add(holder);
  if (entry.holders.length > _holderLimit) {
    entry.holders.removeRange(0, entry.holders.length - _holderLimit);
  }
}

void _traceWatch(
  WidgetRef ref,
  String site,
  Object provider,
  AsyncValue<Object?> value,
) {
  try {
    final context = ref.context;
    final seen = _seen[context];
    if (seen != null &&
        seen.provider == provider &&
        identical(seen.value, value)) {
      return;
    }
    final containers = _containersAbove(context);
    if (containers.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final argument = provider is ProviderBase<Object?>
        ? provider.argument
        : null;
    final _DataEntry? entry;
    if (_untracedSites.contains(site)) {
      entry = _watchEntry(containers.first, site, provider, argument, now);
      _setWatched(entry, value, now);
    } else {
      entry = _findBuild(containers, site, argument);
    }
    if (provider is ProviderBase<Object?>) {
      final family = provider.from;
      if (family != null) _seenSites[family] = site;
    }
    final before = seen?.entry;
    if (before != null && !identical(before, entry)) {
      before.holders.removeWhere((h) => h.element?.target == context);
    }
    if (entry != null) {
      _hold(
        entry,
        _Holder(
          context.widget is SectionView ? HolderKind.section : HolderKind.view,
          now,
          element: WeakReference<BuildContext>(context),
        ),
      );
    }
    _seen[context] = _Seen(provider, value, entry);
  } catch (e) {
    _report(e);
  }
}

/// The record of the app's own [provider] in [container]: one for each provider, and for a
/// listenable that is not a provider (a `.select(...)`), one for each site.
_DataEntry _watchEntry(
  ProviderContainer container,
  String site,
  Object provider,
  Object? argument,
  int now,
) {
  final id = _containerIds[container] ??= ++_containerSeq;
  final key = (id, provider is ProviderBase<Object?> ? provider : site);
  var entry = _data[key];
  if (entry == null) {
    _dropGoneWatched();
    entry = _data[key] = _DataEntry(
      ++_dataSeq,
      key,
      site,
      argument == null ? null : Shown.of(argument),
      id,
      now,
      via: DataVia.watch,
    );
    entry.provider = Shown.of(provider);
    final loose = _loose.remove(key);
    if (loose != null) entry.holders.addAll(loose);
    _postData(entry);
  } else {
    _disposed.remove(entry);
  }
  entry
    ..owner = WeakReference<ProviderContainer>(container)
    ..source = WeakReference<Object>(provider);
  return entry;
}

/// Sets the state of a watched record from what a view got, and posts it when it changed.
void _setWatched(_DataEntry entry, AsyncValue<Object?> value, int now) {
  final String state;
  _Held? held;
  String? error;
  if (value.hasError) {
    state = DataState.error;
    error = _errorText(value.error ?? 'unknown error');
  } else if (value.hasValue) {
    state = DataState.data;
    held = _Held(value.value);
  } else {
    state = DataState.loading;
  }
  final last = entry.lastSeen?.target;
  final changed =
      entry.state != state ||
      entry.error != error ||
      (state == DataState.data &&
          (last == null || !identical(last.value, value.value)));
  entry.lastSeen = WeakReference<AsyncValue<Object?>>(value);
  if (!changed) return;
  entry
    ..state = state
    ..value = held
    ..error = error
    ..updated = now;
  _postData(entry);
}

/// Whether the provider of [entry] is alive in its container, which only a container can say:
/// null when it cannot be known (a `.select(...)`, a container that is gone).
bool? _alive(_DataEntry entry) {
  if (entry.state == DataState.disposed) return false;
  if (entry.via == DataVia.build) return true;
  final container = entry.owner?.target;
  final provider = entry.source?.target;
  if (container == null || provider is! ProviderBase<Object?>) return null;
  return container.exists(provider);
}

void _markDisposed(_DataEntry entry) {
  entry
    ..state = DataState.disposed
    ..updated = DateTime.now().millisecondsSinceEpoch;
  _disposed.add(entry);
  _trimDisposed();
  _postData(entry);
}

/// Marks the app's providers that are gone as disposed. It asks each container once (`exists`
/// reads nothing), and runs when DevTools asks for a snapshot or for holders.
void _refreshWatched() {
  for (final entry in List.of(_data.values)) {
    if (entry.via == DataVia.watch && _alive(entry) == false) {
      _markDisposed(entry);
    }
  }
}

/// Before one more record of an app provider is made, looks for the ones that are gone when
/// there are many, so a family keyed by a product id does not grow without bound.
void _dropGoneWatched() {
  var live = 0;
  for (final e in _data.values) {
    if (e.via == DataVia.watch && e.state != DataState.disposed) live++;
  }
  if (live >= _watchedLimit) _refreshWatched();
}

/// `RouteLink` calls this under `if (kFespalierDevTools)` around its preload, so the handles
/// made inside are `link` holders and not `prefetch` ones. Not exported.
T devToolsAs<T>(String kind, T Function() body) {
  if (!kFespalierDevTools) return body();
  final before = _holderKind;
  _holderKind = kind;
  try {
    return body();
  } finally {
    _holderKind = before;
  }
}

/// `prefetchData` calls this under `if (kFespalierDevTools)`, once [handle] keeps [provider]
/// alive: DevTools lists it as a holder of the provider's record. Not exported.
void devToolsPrefetched(
  WidgetRef ref,
  Object provider,
  PrefetchHandle handle,
  Duration? keepFor,
) {
  if (!kFespalierDevTools) return;
  try {
    if (handle.isClosed) return;
    final containers = _containersAbove(ref.context);
    if (containers.isEmpty) return;
    final holder = _Holder(
      _holderKind,
      DateTime.now().millisecondsSinceEpoch,
      handle: WeakReference<PrefetchHandle>(handle),
      keepFor: keepFor == null || keepFor <= Duration.zero
          ? null
          : keepFor.inMilliseconds,
    );
    final site = _siteOf(provider);
    final argument = provider is ProviderBase<Object?>
        ? provider.argument
        : null;
    if (site != null && !_untracedSites.contains(site)) {
      final entry = _findBuild(containers, site, argument);
      if (entry != null) _hold(entry, holder);
      return;
    }
    final id = _containerIds[containers.first] ??= ++_containerSeq;
    final key = (
      id,
      provider is ProviderBase<Object?> ? provider : (site ?? provider),
    );
    final entry = _data[key];
    if (entry != null) {
      _hold(entry, holder);
      return;
    }
    // No view has watched it yet: kept until one does.
    final list = _loose.putIfAbsent(key, () => []);
    list.removeWhere((h) => h.gone);
    list.add(holder);
    if (_loose.length > _holderLimit) _loose.remove(_loose.keys.first);
  } catch (e) {
    _report(e);
  }
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
  DevToolsMethods.holders: _holdersResponse,
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
    DevToolsFeatures.holders,
    DevToolsFeatures.watched,
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
      _loose.clear();
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

/// The number in the parameter `id`.
int _idParam(Map<String, String> params) {
  final raw = _param(params, 'id');
  final id = int.tryParse(raw);
  if (id == null) {
    throw _Failure(
      developer.ServiceExtensionResponse.invalidParams,
      'parameter `id` is not a number: `$raw`',
    );
  }
  return id;
}

_DataEntry? _entryById(int id) {
  for (final entry in _data.values) {
    if (entry.id == id) return entry;
  }
  return null;
}

/// Asks the provider behind the data record `id` to build again: `ref.invalidateSelf()` on the
/// `Ref` its last build was given, which is held weakly and used only when it is still mounted;
/// for an app's own provider (since 0.8.1), `invalidate` on the container a view saw it in, when
/// it is still alive there.
Map<String, Object?> _invalidate(Map<String, String> params) {
  final entry = _entryById(_idParam(params));
  var ok = false;
  if (entry != null && entry.via == DataVia.watch) {
    final container = entry.owner?.target;
    final provider = entry.source?.target;
    if (container != null &&
        provider is ProviderBase<Object?> &&
        container.exists(provider)) {
      container.invalidate(provider);
      ok = true;
    }
  } else {
    final ref = entry?.ref?.target;
    if (ref != null && ref.mounted) {
      ref.invalidateSelf();
      ok = true;
    }
  }
  return {'protocol': devToolsProtocol, 'ok': ok};
}

/// Who holds the provider of the data record `id` now (since 0.8.1): worked out when asked, so
/// that it is right after a view was unmounted. A view's holder is not dropped when Riverpod
/// removes its listener (that happens before the element is unmounted), but here.
Map<String, Object?> _holdersResponse(Map<String, String> params) {
  final id = _idParam(params);
  final entry = _entryById(id);
  if (entry == null) return HoldersRecord(id: id, found: false).toJson();
  entry.holders.removeWhere((h) => h.gone);
  final alive = _alive(entry);
  if (entry.via == DataVia.watch &&
      alive == false &&
      entry.state != DataState.disposed) {
    _markDisposed(entry);
  }
  final built = entry.via == DataVia.build;
  final listeners = !built
      ? null
      : (entry.state == DataState.disposed ? 0 : entry.listeners);
  final others = listeners == null
      ? null
      : (listeners > entry.holders.length
            ? listeners - entry.holders.length
            : 0);
  return HoldersRecord(
    id: id,
    found: true,
    alive: alive,
    listeners: listeners,
    others: others,
    holders: [for (final h in entry.holders) h.toRecord()],
  ).toJson();
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
  _loose.clear();
  _seenSites.clear();
  _seen = Expando<_Seen>('fespalier views');
  _providers = null;
  _providerSites = null;
  _untraced = null;
  _holderKind = HolderKind.prefetch;
  _actions.clear();
  _dataSeq = 0;
  _containerSeq = 0;
  _containerIds = Expando<int>('fespalier containers');
  _seq = 0;
  _event = 0;
  _last = null;
  _reported = false;
}
