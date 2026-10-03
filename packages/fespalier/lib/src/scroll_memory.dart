import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// The most history entries a router remembers the scroll positions of; the one stored longest
/// ago is forgotten first.
const int _kMaxEntries = 64;

/// What `scroll_restoration: true` (the pubspec's `fespalier:` section) wraps every page in
/// (since 0.8.0): a `PageStorage` for the page's history entry.
///
/// Flutter keeps a scrollable's offset in the nearest `PageStorage`, but only when the
/// scrollable (or a widget above it) has a `PageStorageKey`. A page built for a `go`, a `push`, a
/// link or the first route gets a fresh bucket, so it starts at the top. A page built because
/// the browser brought a history entry back (back, forward, or a reload of the tab) gets the
/// bucket its entry had, so its keyed scrollables return to where they were.
///
/// "The browser brought it back" is what go_router reports: its route information provider
/// keeps the history state the platform gave it, and replaces it with its own marker for every
/// navigation the app starts. A location the platform reports without that state (a link
/// opened from outside) counts as new. On Android and iOS back is a pop, the page below is
/// still mounted and keeps its scroll by being mounted: there is nothing to restore.
///
/// A page that stays mounted while its location changes (`remount: never`, `/c/1` to `/c/2`)
/// keeps its bucket and live scroll positions; the bucket moves to the new location.
///
/// The memory is per router, in memory, and holds at most 64 entries. The same location twice
/// in the history is one entry.
class RouteScrollMemory extends StatefulWidget {
  /// Wraps [child], the page [state] is for.
  const RouteScrollMemory({
    super.key,
    required this.state,
    required this.child,
  });

  /// The route's state: its location is the entry's key (see [scrollKeyOf]).
  final GoRouterState state;

  /// The page.
  final Widget child;

  @override
  State<RouteScrollMemory> createState() => _RouteScrollMemoryState();
}

/// The key a page's scroll positions are kept under: the location matched down to the page,
/// and the query when the page is the leaf of the location.
///
/// So `/search?q=a` and `/search?q=b` are two entries, and `/products` below `/products/42`
/// is `/products`.
String scrollKeyOf(GoRouterState state) {
  final query = state.uri.query;
  final leaf = state.uri.path == state.matchedLocation;
  return leaf && query.isNotEmpty
      ? '${state.matchedLocation}?$query'
      : state.matchedLocation;
}

/// The buckets of one router, by [scrollKeyOf], oldest first.
final class _ScrollStore {
  final LinkedHashMap<String, PageStorageBucket> _buckets = LinkedHashMap();

  /// Removes and returns the bucket of [key].
  PageStorageBucket? take(String key) => _buckets.remove(key);

  /// Keeps [bucket] for [key] as the most recent, forgetting the oldest ones past the cap.
  void put(String key, PageStorageBucket bucket) {
    _buckets.remove(key);
    _buckets[key] = bucket;
    while (_buckets.length > _kMaxEntries) {
      _buckets.remove(_buckets.keys.first);
    }
  }

  /// [bucket] is now the one of [to]; [from] no longer maps to it.
  void move(String from, String to, PageStorageBucket bucket) {
    if (identical(_buckets[from], bucket)) _buckets.remove(from);
    put(to, bucket);
  }
}

/// One store per router, gone with it: nothing here outlives a router, and each test's router
/// starts empty.
final Expando<_ScrollStore> _stores = Expando<_ScrollStore>(
  'fespalier scroll memory',
);

class _RouteScrollMemoryState extends State<RouteScrollMemory> {
  PageStorageBucket? _bucket;
  _ScrollStore? _store;
  late String _key;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bucket != null) return;
    final router = GoRouter.maybeOf(context);
    if (router == null) {
      // A page built by hand, outside a router: a bucket of its own, nothing remembered.
      _bucket = PageStorageBucket();
      return;
    }
    final store = _store = (_stores[router] ??= _ScrollStore());
    final key = _key = scrollKeyOf(widget.state);
    // go_router keeps the history state the platform reports and stores its own marker for
    // every navigation the app starts.
    final fromBrowser =
        router.routeInformationProvider.value.state is! RouteInformationState;
    final bucket = _bucket =
        (fromBrowser ? store.take(key) : null) ?? PageStorageBucket();
    store.put(key, bucket);
  }

  @override
  void didUpdateWidget(RouteScrollMemory oldWidget) {
    super.didUpdateWidget(oldWidget);
    final store = _store;
    if (store == null) return;
    final key = scrollKeyOf(widget.state);
    if (key == _key) return;
    store.move(_key, key, _bucket!);
    _key = key;
  }

  @override
  Widget build(BuildContext context) =>
      PageStorage(bucket: _bucket!, child: widget.child);
}
