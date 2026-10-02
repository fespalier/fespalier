/// The wire format between a running app and fespalier's DevTools extension, protocol 1
/// (since 0.7.0): the names of the service extensions and events, and the records they carry.
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
}

/// The kinds of the events an app posts (`dart:developer`'s `postEvent`, on the `Extension`
/// stream), each carrying `"protocol"` and `"event"` (see [DevToolsEventPayload]).
abstract final class DevToolsEvents {
  /// An app registered, or a router was attached: fetch the tree and a snapshot again.
  static const String registered = 'fespalier:registered';

  /// The router committed a location. The payload's `record` is a [NavigationRecord]; the
  /// snapshot has the location and the stack.
  static const String navigation = 'fespalier:navigation';

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

  /// Everything there is to clear.
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

  /// The response of `snapshot`.
  Map<String, Object?> toJson() => {
    'protocol': protocol,
    'event': event,
    'registered': registered,
    'attached': attached,
    'location': location?.toJson(),
    'stack': [for (final f in stack) f.toJson()],
    'history': [for (final h in history) h.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is SnapshotRecord && _same(toJson(), other.toJson());

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
