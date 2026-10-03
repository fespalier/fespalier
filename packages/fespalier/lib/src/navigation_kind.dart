/// What kind of navigation a committed router configuration is, for DevTools and telemetry
/// (since 0.8.0). Both read the router the same way, so the rule lives here once.
library;

import 'package:go_router/go_router.dart';

import 'devtools/protocol.dart' show NavigationKind;

/// What the router's configuration was at a commit: how many pages were pushed, the location
/// below them (`base`), the location on top (`leaf`) and the key of the page on top (`top`),
/// which is null when nothing was pushed.
typedef NavSnapshot = ({int depth, String base, String leaf, String? top});

/// The pushed pages in [matches], oldest first (a pushed page inside a shell is in the shell's
/// matches).
void pushedMatches(
  List<RouteMatchBase> matches,
  List<ImperativeRouteMatch> out,
) {
  for (final m in matches) {
    if (m is ImperativeRouteMatch) {
      out.add(m);
    } else if (m is ShellRouteMatch) {
      pushedMatches(m.matches, out);
    }
  }
}

/// Where [config] is: the list of the page on top (what [GoRouterState] of that page reads),
/// which is [config] itself when nothing was pushed.
RouteMatchList activeMatches(
  RouteMatchList config,
  List<ImperativeRouteMatch> pushed,
) => pushed.isEmpty ? config : pushed.last.matches;

/// Classifies the commit of [config] against what the last commit left ([before], null for the
/// first one): the [NavigationKind] value, and the snapshot to pass as [before] next time.
({String kind, NavSnapshot now}) classifyNavigation(
  RouteMatchList config,
  NavSnapshot? before,
) {
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(config.matches, pushed);
  final active = activeMatches(config, pushed);
  final depth = pushed.length;
  final top = pushed.isEmpty ? null : pushed.last.pageKey.value;
  final base = config.uri.toString();
  final leaf = active.uri.toString();
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
  return (kind: kind, now: (depth: depth, base: base, leaf: leaf, top: top));
}
