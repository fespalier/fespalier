/// The wire format between a running app and fespalier's DevTools extension, protocol 1
/// (since 0.7.0): the names of the service extensions and events, and the records they carry.
/// What 0.8.0 added (`holders`, and a data record's `via`, `provider` and `listeners`) is
/// additive, so it is still protocol 1.
///
/// This file imports nothing, so the extension (a Flutter web app that cannot import
/// `package:fespalier`) holds a byte-identical copy: `scripts/build-devtools-extension.sh`
/// writes it to `packages/fespalier_devtools/lib/src/protocol.dart`, and a test there fails when
/// the two differ. Edit this one.
///
/// The rules that keep protocol 1 additive:
///
/// - Every response and every event carries `"protocol": 1`. A change that removes or renames
///   something, or changes what a field means, is protocol 2. Adding a method, an event kind, a
///   record, an optional field or a feature name is not.
/// - A `fromJson` ignores keys it does not know and reads a missing optional key as its default,
///   so an extension reads what a newer runtime sends, and the other way round.
/// - What an app can answer is listed in `hello`'s `features`; an extension asks only for what is
///   listed.
/// - A user value (an `extra`, a parsed parameter) is never sent raw, but as a [Shown]: its type
///   and a cut-off text.
/// - Timestamps are milliseconds since the epoch.
library;

/// The protocol this file describes. Every response and event carries it as `"protocol"`.
const int devToolsProtocol = 1;

/// The most characters of a user value's text that a [Shown] keeps.
const int shownTextLimit = 200;

/// The text of a [Shown] whose value's `toString` threw.
const String shownThrew = '<toString threw>';

/// The names of the service extensions an app registers (`dart:developer`'s
/// `registerExtension`), each answering with a JSON object.
abstract final class DevToolsMethods {
  /// No parameters. Answers a [HelloRecord]: the protocol, and what this app can do.
  static const String hello = 'ext.fespalier.hello';

  /// No parameters. Answers `{"protocol": 1, "tree": <the route tree> | null}`: the tree `fsp`
  /// wrote into `app.g.dart` (the same JSON as `fsp routes --graph json`), parsed.
  static const String tree = 'ext.fespalier.tree';

  /// No parameters. Answers a [SnapshotRecord]: the location, the stack and the history.
  static const String snapshot = 'ext.fespalier.snapshot';

  /// Parameter `location`. Answers a [MatchRecord]: the route the generated matcher gives the
  /// location. It runs no guard and builds nothing.
  static const String match = 'ext.fespalier.match';

  /// Parameters `mode` ([NavigateMode]) and `location` (not for `pop`). Answers
  /// `{"protocol": 1, "ok": true}` once the router has been asked.
  static const String navigate = 'ext.fespalier.navigate';

  /// Parameter `what` ([ClearWhat]). Answers `{"protocol": 1, "ok": true}`: the buffers named
  /// are emptied, and the event counter keeps counting.
  static const String clear = 'ext.fespalier.clear';

  /// Parameter `id` (a [DataRecord]'s). Answers `{"protocol": 1, "ok": bool}`: `ok` is true when
  /// the provider that built the record was still alive and was invalidated, so it builds again
  /// when something reads it. Listed in `hello`'s features as [DevToolsFeatures.data].
  static const String invalidate = 'ext.fespalier.invalidate';

  /// Parameter `file`, relative to the app folder as the tree's `file`s are. Answers
  /// `{"protocol": 1, "ok": true}` once the IDE was asked to open it: a `navigate` event on the
  /// `ToolEvent` stream with a `package:` URI. Listed as [DevToolsFeatures.open].
  static const String open = 'ext.fespalier.open';

  /// Parameter `id` (a [DataRecord]'s), since 0.8.0. Answers a [HoldersRecord]: who holds that
  /// provider now, computed when asked. Listed as [DevToolsFeatures.holders].
  static const String holders = 'ext.fespalier.holders';
}

/// The kinds of the events an app posts (`dart:developer`'s `postEvent`, on the `Extension`
/// stream), each carrying `"protocol"` and `"event"` (see [DevToolsEventPayload]).
abstract final class DevToolsEvents {
  /// An app registered, or a router was attached: fetch the tree and a snapshot again.
  static const String registered = 'fespalier:registered';

  /// The router committed a location. The payload's `record` is a [NavigationRecord]; the
  /// snapshot has the location and the stack.
  static const String navigation = 'fespalier:navigation';

  /// A guard or a `redirect.dart` answered, or an asynchronous one settled (the same `seq`
  /// again). The payload's `record` is a [GuardRecord].
  static const String guard = 'fespalier:guard';

  /// A `data.dart` provider was built, settled, failed, rebuilt or disposed. The payload's
  /// `record` is a [DataRecord].
  static const String data = 'fespalier:data';

  /// An action started or ended. The payload's `record` is an [ActionRecord].
  static const String action = 'fespalier:action';

  /// Whether a stream event of this kind is fespalier's.
  static bool isFespalier(String kind) => kind.startsWith('fespalier:');
}

/// The names `hello` lists in `features`: what an app can answer.
abstract final class DevToolsFeatures {
  /// `location`, `stack` and `history` in the snapshot, and the `navigation` event.
  static const String navigation = 'navigation';

  /// The `match` method.
  static const String match = 'match';

  /// The `navigate` method.
  static const String navigate = 'navigate';

  /// The guard decisions: `guards` in the snapshot, the `guard` event, and the `guards` of a
  /// [NavigationRecord].
  static const String guards = 'guards';

  /// The state of the `data.dart` providers: `data` in the snapshot, the `data` event, and
  /// the `invalidate` method.
  static const String data = 'data';

  /// The runs of the actions: `actions` in the snapshot and the `action` event.
  static const String actions = 'actions';

  /// The `open` method.
  static const String open = 'open';

  /// The `holders` method, and a [DataRecord]'s `listeners` (since 0.8.0).
  static const String holders = 'holders';

  /// A `data.dart` that returns or selects the app's own provider is followed too: the
  /// [DataRecord]s with `via` [DataVia.watch] (since 0.8.0).
  static const String watched = 'watched';
}

/// The values of `navigate`'s `mode`.
abstract final class NavigateMode {
  /// `GoRouter.go`.
  static const String go = 'go';

  /// `GoRouter.push`; what the page pops with is not given.
  static const String push = 'push';

  /// `GoRouter.replace`.
  static const String replace = 'replace';

  /// `GoRouter.pop`, only when something can pop. It takes no `location`.
  static const String pop = 'pop';

  /// Every mode.
  static const List<String> all = [go, push, replace, pop];
}

/// The values of `clear`'s `what`.
abstract final class ClearWhat {
  /// The navigation history.
  static const String history = 'history';

  /// The guard decisions.
  static const String guards = 'guards';

  /// The action runs.
  static const String actions = 'actions';

  /// Everything there is to clear: the history, the guards, the actions and the records of
  /// disposed providers (the live ones stay).
  static const String all = 'all';
}

/// The values of a [NavigationRecord]'s `kind`. A kind is a guess made from the router's
/// configuration before and after the commit, so a reader treats an unknown one as a plain
/// change of location.
abstract final class NavigationKind {
  /// The first location the router committed.
  static const String initial = 'initial';

  /// `go`, a link, the address bar or a redirect: the declarative stack changed.
  static const String go = 'go';

  /// A page was pushed: more imperative matches than before.
  static const String push = 'push';

  /// A pushed page was popped: fewer imperative matches, and the location below is unchanged.
  static const String pop = 'pop';

  /// The page on top of the pushed ones was replaced.
  static const String replace = 'replace';

  /// The same location again, as the router was refreshed or `go` repeated it with another
  /// `extra`.
  static const String refresh = 'refresh';
}

/// The values of a [GuardRecord]'s `result`.
abstract final class GuardOutcome {
  /// The guard let the navigation through (it returned `null`).
  static const String pass = 'pass';

  /// The guard sent the navigation elsewhere: the record's `location`.
  static const String redirect = 'redirect';

  /// An asynchronous guard has not answered yet.
  static const String pending = 'pending';

  /// The guard threw, or its `Future` failed: go_router gets the error as before.
  static const String error = 'error';

  /// The route's segments did not parse, so the guard did not run and the page shows not found.
  static const String skipped = 'skipped';
}

/// The values of a [DataRecord]'s `state`.
abstract final class DataState {
  /// The provider's `Future` is pending.
  static const String loading = 'loading';

  /// The provider has a value.
  static const String data = 'data';

  /// The provider's `Future` failed.
  static const String error = 'error';

  /// The provider returned a `Stream`. It is not listened to, so there is no value to show.
  static const String stream = 'stream';

  /// The provider was disposed (nothing watched it any more, or it was invalidated and has not
  /// been read since).
  static const String disposed = 'disposed';
}

/// The values of a [DataRecord]'s `via`: how fespalier follows the provider (since 0.8.0).
abstract final class DataVia {
  /// fespalier built the provider (the function form of `data.dart`) and sees each build.
  static const String build = 'build';

  /// The app's own provider (a `data.dart` that returns or selects one), seen through what
  /// fespalier's views watched: no build count, and no other listeners.
  static const String watch = 'watch';
}

/// The values of a [HolderRecord]'s `kind` (since 0.8.0): what keeps a provider alive that
/// fespalier made.
abstract final class HolderKind {
  /// The route's `DataView`.
  static const String view = 'view';

  /// A section's `SectionView`.
  static const String section = 'section';

  /// A `PrefetchHandle` (`XRoute.prefetch`, `preload`, `prefetchAll`).
  static const String prefetch = 'prefetch';

  /// A `RouteLink` preload.
  static const String link = 'link';
}

/// The values of an [ActionRecord]'s `state`.
abstract final class ActionState {
  /// The action's `Future` is pending.
  static const String running = 'running';

  /// The action succeeded.
  static const String done = 'done';

  /// The action threw, or its `Future` failed.
  static const String error = 'error';
}

/// The values of a [FrameRecord]'s `type`.
abstract final class FrameType {
  /// A route of the declarative stack (`GoRoute`).
  static const String page = 'page';

  /// A page that was pushed (`context.push`). Its children are the matches it shows.
  static const String pushed = 'pushed';

  /// A `ShellRoute` or `StatefulShellRoute`. Its children are what it shows.
  static const String shell = 'shell';
}

/// The payload every event has: the protocol, and the event's number.
///
/// `event` is one counter per isolate across all kinds. A reader that sees a number other than
/// its last plus one fetches the snapshot again.
abstract final class DevToolsEventPayload {
  /// The key of the event's number.
  static const String event = 'event';

  /// The key of the event's record, for the kinds that have one.
  static const String record = 'record';
}

/// A user value shown without sending it: its runtime type, and its `toString`, cut to
/// [shownTextLimit] characters (then `…`).
final class Shown {
  /// A value of type [type] that reads [text].
  const Shown(this.type, this.text);

  /// Describes [value]: a `toString` that throws gives [shownThrew].
  factory Shown.of(Object? value) {
    String text;
    try {
      text = '$value';
    } catch (_) {
      text = shownThrew;
    }
    if (text.length > shownTextLimit) {
      text = '${text.substring(0, shownTextLimit)}…';
    }
    return Shown('${value.runtimeType}', text);
  }

  /// Reads what [toJson] wrote.
  factory Shown.fromJson(Map<String, Object?> json) =>
      Shown(_string(json, 'type'), _string(json, 'text'));

  /// The value's runtime type, as `runtimeType.toString()` spells it.
  final String type;

  /// The value's text, cut off.
  final String text;

  /// `{"type": …, "text": …}`.
  Map<String, Object?> toJson() => {'type': type, 'text': text};

  @override
  bool operator ==(Object other) =>
      other is Shown && other.type == type && other.text == text;

  @override
  int get hashCode => Object.hash(type, text);

  @override
  String toString() => 'Shown($type, $text)';
}

/// What `hello` answers: whether this app speaks the protocol, and what it can do.
final class HelloRecord {
  /// A hello for protocol [protocol].
  const HelloRecord({
    this.protocol = devToolsProtocol,
    required this.registered,
    required this.attached,
    required this.features,
  });

  /// Reads what [toJson] wrote.
  factory HelloRecord.fromJson(Map<String, Object?> json) => HelloRecord(
    protocol: _int(json, 'protocol'),
    registered: _bool(json, 'registered'),
    attached: _bool(json, 'attached'),
    features: _strings(json, 'features'),
  );

  /// The protocol the app speaks.
  final int protocol;

  /// Whether the generated `mount()` has run, so the app has a route tree.
  final bool registered;

  /// Whether a router is attached: without one, there is no location to show.
  final bool attached;

  /// What the app can answer, by [DevToolsFeatures] name.
  final List<String> features;

  /// The response of `hello`.
  Map<String, Object?> toJson() => {
    'protocol': protocol,
    'registered': registered,
    'attached': attached,
    'features': features,
  };

  @override
  bool operator ==(Object other) =>
      other is HelloRecord && _same(toJson(), other.toJson());

  @override
  int get hashCode => _hash(toJson());
}

/// Where the router is: the committed configuration, and the route fespalier's matcher gives it.
final class LocationRecord {
  /// A location.
  const LocationRecord({
    required this.uri,
    required this.fullPath,
    required this.pathParameters,
    required this.query,
    this.extra,
    this.route,
    this.params,
    this.error,
  });

  /// Reads what [toJson] wrote.
  factory LocationRecord.fromJson(Map<String, Object?> json) => LocationRecord(
    uri: _string(json, 'uri'),
    fullPath: _string(json, 'fullPath'),
    pathParameters: _stringMap(json, 'pathParameters'),
    query: {
      for (final e in _map(json, 'query').entries)
        e.key: [for (final v in (e.value as List<Object?>?) ?? const []) '$v'],
    },
    extra: _shownOrNull(json, 'extra'),
    route: _stringOrNull(json, 'route'),
    params: json['params'] == null
        ? null
        : {
            for (final e in _map(json, 'params').entries)
              e.key: Shown.fromJson(e.value! as Map<String, Object?>),
          },
    error: _stringOrNull(json, 'error'),
  );

  /// The location on top of the stack, as a string (`/products/2?tab=info`): the page a `push`
  /// put there when there is one.
  final String uri;

  /// The route path template it matched (`/products/:id`); empty when nothing matched.
  final String fullPath;

  /// go_router's path parameters, decoded, as strings.
  final Map<String, String> pathParameters;

  /// The query, each key with all its values.
  final Map<String, List<String>> query;

  /// The `extra` the navigation carried.
  final Shown? extra;

  /// The typed route class fespalier's matcher gives [uri] (`ProductRoute`), or null when none
  /// does (or no matcher is registered).
  final String? route;

  /// The parameters fespalier parsed from [uri], by name, in their declared types. Null when
  /// [route] is.
  final Map<String, Shown>? params;

  /// What go_router says when nothing matched (`GoException: no routes for location: …`).
  final String? error;

  /// A part of a [SnapshotRecord].
  Map<String, Object?> toJson() => {
    'uri': uri,
    'fullPath': fullPath,
    'pathParameters': pathParameters,
    'query': query,
    'extra': extra?.toJson(),
    'route': route,
    'params': params?.map((k, v) => MapEntry(k, v.toJson())),
    'error': error,
  };

  @override
  bool operator ==(Object other) =>
      other is LocationRecord && _same(toJson(), other.toJson());

  @override
  int get hashCode => _hash(toJson());
}

/// One entry of the router's stack, and what it holds.
final class FrameRecord {
  /// A frame.
  const FrameRecord({
    required this.type,
    required this.path,
    required this.location,
    required this.pageKey,
    this.children = const [],
  });

  /// Reads what [toJson] wrote.
  factory FrameRecord.fromJson(Map<String, Object?> json) => FrameRecord(
    type: _string(json, 'type'),
    path: _string(json, 'path'),
    location: _string(json, 'location'),
    pageKey: _string(json, 'pageKey'),
    children: [
      for (final c in _list(json, 'children'))
        FrameRecord.fromJson(c! as Map<String, Object?>),
    ],
  );

  /// A [FrameType].
  final String type;

  /// The path template from the root down to this match (`/products/:id`).
  final String path;

  /// The part of the location this match is for (`/products/2`).
  final String location;

  /// go_router's key for the page.
  final String pageKey;

  /// What a shell shows, or what a pushed page's own matches are.
  final List<FrameRecord> children;

  /// A part of a [SnapshotRecord].
  Map<String, Object?> toJson() => {
    'type': type,
    'path': path,
    'location': location,
    'pageKey': pageKey,
    'children': [for (final c in children) c.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is FrameRecord && _same(toJson(), other.toJson());

  @override
  int get hashCode => _hash(toJson());
}

/// One committed location, as the router's delegate announced it.
final class NavigationRecord {
  /// A navigation.
  const NavigationRecord({
    required this.seq,
    required this.at,
    required this.kind,
    required this.uri,
    required this.fullPath,
    required this.depth,
    this.guards = const [],
    this.error,
  });

  /// Reads what [toJson] wrote.
  factory NavigationRecord.fromJson(Map<String, Object?> json) =>
      NavigationRecord(
        seq: _int(json, 'seq'),
        at: _int(json, 'at'),
        kind: _string(json, 'kind'),
        uri: _string(json, 'uri'),
        fullPath: _string(json, 'fullPath'),
        depth: _int(json, 'depth'),
        guards: [for (final g in _list(json, 'guards')) g! as int],
        error: _stringOrNull(json, 'error'),
      );

  /// A number for the record, one counter per isolate for every kind of record.
  final int seq;

  /// When it was committed, in milliseconds since the epoch.
  final int at;

  /// A [NavigationKind].
  final String kind;

  /// The location on top of the stack, as [LocationRecord.uri].
  final String uri;

  /// The route path template it matched.
  final String fullPath;

  /// How many pushed pages are in the stack.
  final int depth;

  /// The `seq`s of the [GuardRecord]s that answered since the previous commit: the decisions
  /// behind this navigation, a redirect chain (`/admin` to `/login`) included. Empty when the
  /// app lists no [DevToolsFeatures.guards] or no guard ran.
  final List<int> guards;

  /// What go_router says when nothing matched.
  final String? error;

  /// A part of a [SnapshotRecord] and of the `navigation` event.
  Map<String, Object?> toJson() => {
    'seq': seq,
    'at': at,
    'kind': kind,
    'uri': uri,
    'fullPath': fullPath,
    'depth': depth,
    'guards': guards,
    'error': error,
  };

  @override
  bool operator ==(Object other) =>
      other is NavigationRecord && _same(toJson(), other.toJson());

  @override
  int get hashCode => _hash(toJson());
}

/// What `snapshot` answers: everything the live state of the router has, in one call.
final class SnapshotRecord {
  /// A snapshot as of event [event].
  const SnapshotRecord({
    this.protocol = devToolsProtocol,
    required this.event,
    required this.registered,
    required this.attached,
    this.location,
    this.stack = const [],
    this.history = const [],
    this.guards = const [],
    this.data = const [],
    this.actions = const [],
  });

  /// Reads what [toJson] wrote.
  factory SnapshotRecord.fromJson(Map<String, Object?> json) => SnapshotRecord(
    protocol: _int(json, 'protocol'),
    event: _int(json, 'event'),
    registered: _bool(json, 'registered'),
    attached: _bool(json, 'attached'),
    location: json['location'] == null
        ? null
        : LocationRecord.fromJson(json['location']! as Map<String, Object?>),
    stack: [
      for (final f in _list(json, 'stack'))
        FrameRecord.fromJson(f! as Map<String, Object?>),
    ],
    history: [
      for (final h in _list(json, 'history'))
        NavigationRecord.fromJson(h! as Map<String, Object?>),
    ],
    guards: [
      for (final g in _list(json, 'guards'))
        GuardRecord.fromJson(g! as Map<String, Object?>),
    ],
    data: [
      for (final d in _list(json, 'data'))
        DataRecord.fromJson(d! as Map<String, Object?>),
    ],
    actions: [
      for (final a in _list(json, 'actions'))
        ActionRecord.fromJson(a! as Map<String, Object?>),
    ],
  );

  /// The protocol the app speaks.
  final int protocol;

  /// The number of the last event, so an event that arrives with a number up to it is already
  /// in here.
  final int event;

  /// Whether the generated `mount()` has run.
  final bool registered;

  /// Whether a router is attached.
  final bool attached;

  /// Where the router is; null with no router, or before it committed a location.
  final LocationRecord? location;

  /// The router's stack, bottom first.
  final List<FrameRecord> stack;

  /// The committed locations, oldest first.
  final List<NavigationRecord> history;

  /// The guard decisions, oldest first. Empty without [DevToolsFeatures.guards].
  final List<GuardRecord> guards;

  /// The `data.dart` providers, in the order they were first built: the live ones, then the
  /// latest disposed. Empty without [DevToolsFeatures.data].
  final List<DataRecord> data;

  /// The action runs, oldest first. Empty without [DevToolsFeatures.actions].
  final List<ActionRecord> actions;

  /// The response of `snapshot`.
  Map<String, Object?> toJson() => {
    'protocol': protocol,
    'event': event,
    'registered': registered,
    'attached': attached,
    'location': location?.toJson(),
    'stack': [for (final f in stack) f.toJson()],
    'history': [for (final h in history) h.toJson()],
    'guards': [for (final g in guards) g.toJson()],
    'data': [for (final d in data) d.toJson()],
    'actions': [for (final a in actions) a.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is SnapshotRecord && _same(toJson(), other.toJson());

  @override
  int get hashCode => _hash(toJson());
}

/// One answer of a guard or a `redirect.dart`, as the generated `redirect:` got it.
///
/// An asynchronous guard is first `pending`, then the same record (same `seq`) is sent again
/// with its result and `ms`.
final class GuardRecord {
  /// A guard decision.
  const GuardRecord({
    required this.seq,
    required this.at,
    required this.site,
    required this.uri,
    required this.fullPath,
    required this.result,
    this.location,
    this.isAsync = false,
    this.ms = 0,
    this.error,
  });

  /// Reads what [toJson] wrote.
  factory GuardRecord.fromJson(Map<String, Object?> json) => GuardRecord(
    seq: _int(json, 'seq'),
    at: _int(json, 'at'),
    site: _string(json, 'site'),
    uri: _string(json, 'uri'),
    fullPath: _string(json, 'fullPath'),
    result: _string(json, 'result'),
    location: _stringOrNull(json, 'location'),
    isAsync: json['async'] == true,
    ms: (json['ms'] as int?) ?? 0,
    error: _stringOrNull(json, 'error'),
  );

  /// A number for the record, from the same counter as [NavigationRecord.seq].
  final int seq;

  /// When the guard answered (or, for a `pending` one, was called), in milliseconds since the
  /// epoch.
  final int at;

  /// Which guard: a key of the tree's `sites` (`g5@6`, or `r32` for a `redirect.dart`).
  final String site;

  /// The location the navigation was going to.
  final String uri;

  /// The route path template of that location, as far as go_router knows it at that point.
  final String fullPath;

  /// A [GuardOutcome].
  final String result;

  /// Where the guard sent the navigation, for a `redirect`.
  final String? location;

  /// Whether the guard returned a `Future`. (`async` is the JSON key.)
  final bool isAsync;

  /// How long an asynchronous guard took to answer, in milliseconds. 0 for one that answered
  /// at once.
  final int ms;

  /// What the guard threw, for an `error`.
  final String? error;

  /// A part of a [SnapshotRecord] and of the `guard` event.
  Map<String, Object?> toJson() => {
    'seq': seq,
    'at': at,
    'site': site,
    'uri': uri,
    'fullPath': fullPath,
    'result': result,
    'location': location,
    'async': isAsync,
    'ms': ms,
    'error': error,
  };

  @override
  bool operator ==(Object other) =>
      other is GuardRecord && _same(toJson(), other.toJson());

  @override
  int get hashCode => _hash(toJson());
}

/// One provider built from a `data.dart`: the state of what a route loads. There is one record
/// for each container, site and key.
final class DataRecord {
  /// A data record.
  const DataRecord({
    required this.id,
    required this.site,
    this.key,
    required this.container,
    required this.state,
    required this.builds,
    required this.created,
    required this.updated,
    this.value,
    this.error,
    this.via = DataVia.build,
    this.provider,
    this.listeners,
  });

  /// Reads what [toJson] wrote.
  factory DataRecord.fromJson(Map<String, Object?> json) => DataRecord(
    id: _int(json, 'id'),
    site: _string(json, 'site'),
    key: _shownOrNull(json, 'key'),
    container: _int(json, 'container'),
    state: _string(json, 'state'),
    builds: _int(json, 'builds'),
    created: _int(json, 'created'),
    updated: _int(json, 'updated'),
    value: _shownOrNull(json, 'value'),
    error: _stringOrNull(json, 'error'),
    via: _stringOrNull(json, 'via') ?? DataVia.build,
    provider: _shownOrNull(json, 'provider'),
    listeners: json['listeners'] as int?,
  );

  /// A number for the record, one counter per isolate; what `invalidate` takes.
  final int id;

  /// Which `data.dart`: a key of the tree's `sites` (`d37`).
  final String site;

  /// What the family is keyed by (a route's segments and query), or null for a provider with
  /// no keys.
  final Shown? key;

  /// Which `ProviderContainer` it lives in, by a number the app gave it (the first one is 1).
  final int container;

  /// A [DataState].
  final String state;

  /// How many times the provider's body ran.
  final int builds;

  /// When it was first built, in milliseconds since the epoch.
  final int created;

  /// When its state last changed.
  final int updated;

  /// The value, for `data`.
  final Shown? value;

  /// What the `Future` failed with, for `error`.
  final String? error;

  /// A [DataVia] (since 0.8.0); an older app's record is [DataVia.build].
  final String via;

  /// The provider the app's own `data.dart` returned or selected, as its `toString` spells it,
  /// for [DataVia.watch]; null otherwise (since 0.8.0).
  final Shown? provider;

  /// How many listeners the provider has now, for [DataVia.build]; null for [DataVia.watch], and
  /// for an app older than 0.8.0 (since 0.8.0).
  final int? listeners;

  /// A part of a [SnapshotRecord] and of the `data` event.
  Map<String, Object?> toJson() => {
    'id': id,
    'site': site,
    'key': key?.toJson(),
    'container': container,
    'state': state,
    'builds': builds,
    'created': created,
    'updated': updated,
    'value': value?.toJson(),
    'error': error,
    'via': via,
    'provider': provider?.toJson(),
    'listeners': listeners,
  };

  @override
  bool operator ==(Object other) =>
      other is DataRecord && _same(toJson(), other.toJson());

  @override
  int get hashCode => _hash(toJson());
}

/// One holder of a provider that fespalier knows (since 0.8.0).
final class HolderRecord {
  /// A holder of [kind] (a [HolderKind]).
  const HolderRecord({required this.kind, required this.since, this.keepFor});

  /// Reads what [toJson] wrote.
  factory HolderRecord.fromJson(Map<String, Object?> json) => HolderRecord(
    kind: _string(json, 'kind'),
    since: _int(json, 'since'),
    keepFor: json['keepFor'] as int?,
  );

  /// A [HolderKind].
  final String kind;

  /// When fespalier first saw it, in milliseconds since the epoch.
  final int since;

  /// For a prefetch or a link: the `keepFor` it was given, in milliseconds; null for until it is
  /// closed, and for a view.
  final int? keepFor;

  /// A part of a [HoldersRecord].
  Map<String, Object?> toJson() => {
    'kind': kind,
    'since': since,
    'keepFor': keepFor,
  };

  @override
  bool operator ==(Object other) =>
      other is HolderRecord && _same(toJson(), other.toJson());

  @override
  int get hashCode => _hash(toJson());
}

/// What `holders` answers (since 0.8.0): who keeps the provider of a [DataRecord] alive now.
final class HoldersRecord {
  /// The answer for the record [id].
  const HoldersRecord({
    this.protocol = devToolsProtocol,
    required this.id,
    required this.found,
    this.alive,
    this.listeners,
    this.others,
    this.holders = const [],
  });

  /// Reads what [toJson] wrote.
  factory HoldersRecord.fromJson(Map<String, Object?> json) => HoldersRecord(
    protocol: _int(json, 'protocol'),
    id: _int(json, 'id'),
    found: _bool(json, 'found'),
    alive: json['alive'] as bool?,
    listeners: json['listeners'] as int?,
    others: json['others'] as int?,
    holders: [
      for (final h in _list(json, 'holders'))
        HolderRecord.fromJson(h! as Map<String, Object?>),
    ],
  );

  /// The protocol the app speaks.
  final int protocol;

  /// The record that was asked about.
  final int id;

  /// False for an id that is not (or no longer) tracked; the other fields are then absent.
  final bool found;

  /// Whether the provider is alive in its container; null when that cannot be known (a
  /// `.select(...)`, a container that is gone).
  final bool? alive;

  /// How many listeners a provider fespalier built has; null for the app's own provider.
  final int? listeners;

  /// The listeners fespalier does not know a holder of: `listeners` minus the holders, never
  /// below 0; null for the app's own provider.
  final int? others;

  /// The holders fespalier created, oldest first.
  final List<HolderRecord> holders;

  /// The response of `holders`.
  Map<String, Object?> toJson() => {
    'protocol': protocol,
    'id': id,
    'found': found,
    if (found) ...{
      'alive': alive,
      'listeners': listeners,
      'others': others,
      'holders': [for (final h in holders) h.toJson()],
    },
  };

  @override
  bool operator ==(Object other) =>
      other is HoldersRecord && _same(toJson(), other.toJson());

  @override
  int get hashCode => _hash(toJson());
}

/// One run of an action: sent when it starts and again when it ends, with the same `seq`.
final class ActionRecord {
  /// An action run.
  const ActionRecord({
    required this.seq,
    required this.site,
    this.key,
    required this.input,
    required this.state,
    required this.started,
    this.ms,
    this.result,
    this.error,
  });

  /// Reads what [toJson] wrote.
  factory ActionRecord.fromJson(Map<String, Object?> json) => ActionRecord(
    seq: _int(json, 'seq'),
    site: _string(json, 'site'),
    key: _shownOrNull(json, 'key'),
    input: Shown.fromJson(json['input']! as Map<String, Object?>),
    state: _string(json, 'state'),
    started: _int(json, 'started'),
    ms: json['ms'] as int?,
    result: _shownOrNull(json, 'result'),
    error: _stringOrNull(json, 'error'),
  );

  /// A number for the record, from the same counter as [NavigationRecord.seq].
  final int seq;

  /// Which action: a key of the tree's `sites` (`a37_0`).
  final String site;

  /// What the action's family is keyed by, or null for an action with no keys.
  final Shown? key;

  /// What the action was called with.
  final Shown input;

  /// An [ActionState].
  final String state;

  /// When the run started, in milliseconds since the epoch.
  final int started;

  /// How long it took, once it ended.
  final int? ms;

  /// What it returned, for `done`.
  final Shown? result;

  /// What it threw, for `error`.
  final String? error;

  /// A part of a [SnapshotRecord] and of the `action` event.
  Map<String, Object?> toJson() => {
    'seq': seq,
    'site': site,
    'key': key?.toJson(),
    'input': input.toJson(),
    'state': state,
    'started': started,
    'ms': ms,
    'result': result?.toJson(),
    'error': error,
  };

  @override
  bool operator ==(Object other) =>
      other is ActionRecord && _same(toJson(), other.toJson());

  @override
  int get hashCode => _hash(toJson());
}

/// What `match` answers: the route a location is, or none.
final class MatchRecord {
  /// The answer for [location]: no [route] when nothing matches.
  const MatchRecord({
    this.protocol = devToolsProtocol,
    required this.location,
    this.route,
    this.params = const {},
    this.data = 0,
  });

  /// Reads what [toJson] wrote.
  factory MatchRecord.fromJson(Map<String, Object?> json) {
    final match = json['match'] as Map<String, Object?>?;
    return MatchRecord(
      protocol: _int(json, 'protocol'),
      location: _string(json, 'location'),
      route: match == null ? null : _string(match, 'route'),
      params: match == null
          ? const {}
          : {
              for (final e in _map(match, 'params').entries)
                e.key: Shown.fromJson(e.value! as Map<String, Object?>),
            },
      data: match == null ? 0 : _int(match, 'data'),
    );
  }

  /// The protocol the app speaks.
  final int protocol;

  /// The location that was matched, as given.
  final String location;

  /// The typed route class (`ProductRoute`), or null when no route fits, or a segment does not
  /// parse (the not-found rule).
  final String? route;

  /// The parameters parsed from [location], by name.
  final Map<String, Shown> params;

  /// How many providers the route's data is (each section's, then its own).
  final int data;

  /// The response of `match`: `"match"` is null when no route fits.
  Map<String, Object?> toJson() => {
    'protocol': protocol,
    'location': location,
    'match': route == null
        ? null
        : {
            'route': route,
            'params': params.map((k, v) => MapEntry(k, v.toJson())),
            'data': data,
          },
  };

  @override
  bool operator ==(Object other) =>
      other is MatchRecord && _same(toJson(), other.toJson());

  @override
  int get hashCode => _hash(toJson());
}

String _string(Map<String, Object?> json, String key) => json[key]! as String;

String? _stringOrNull(Map<String, Object?> json, String key) =>
    json[key] as String?;

int _int(Map<String, Object?> json, String key) => json[key]! as int;

bool _bool(Map<String, Object?> json, String key) => json[key]! as bool;

List<Object?> _list(Map<String, Object?> json, String key) =>
    (json[key] as List<Object?>?) ?? const [];

List<String> _strings(Map<String, Object?> json, String key) => [
  for (final v in _list(json, key)) '$v',
];

Map<String, Object?> _map(Map<String, Object?> json, String key) =>
    (json[key] as Map<String, Object?>?) ?? const {};

Map<String, String> _stringMap(Map<String, Object?> json, String key) => {
  for (final e in _map(json, key).entries) e.key: '${e.value}',
};

Shown? _shownOrNull(Map<String, Object?> json, String key) => json[key] == null
    ? null
    : Shown.fromJson(json[key]! as Map<String, Object?>);

/// Whether two decoded JSON values are equal, maps and lists by content.
bool _same(Object? a, Object? b) {
  if (a is Map<Object?, Object?> && b is Map<Object?, Object?>) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_same(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// A hash that agrees with [_same].
int _hash(Object? value) {
  if (value is Map<Object?, Object?>) {
    var hash = 0;
    for (final e in value.entries) {
      hash ^= Object.hash(e.key, _hash(e.value));
    }
    return hash;
  }
  if (value is List<Object?>) return Object.hashAll(value.map(_hash));
  return value.hashCode;
}
