import 'package:flutter/widgets.dart';

import 'route_match.dart';

/// A `not_found.dart` below the root: the URL prefix of its folder (a segment
/// starting with `:` matches anything, and a localized folder is all its
/// spellings joined by `|`: `products|produits`), the widget to show, and whether the
/// folder's own path matches by case (its `route.dart`, else the config).
typedef NotFoundScope = (
  List<String> prefix,
  Widget Function(Uri uri) build, {
  bool caseSensitive,
});

/// The generated `notFound(uri)`: the not-found view of the deepest folder that
/// [uri] is under, or [root] when none is.
///
/// [scopes] are ordered nearest first, and each compares its own prefix by its
/// own case setting: with it off, `/Products` is under `products/`. [base] is
/// where the tree is mounted, compared by [caseSensitive], the root folder's
/// setting.
Widget nearestNotFound(
  Uri uri,
  String base,
  List<NotFoundScope> scopes,
  Widget Function(Uri uri) root, {
  bool caseSensitive = true,
}) {
  final path = pathBelow(uri, base, caseSensitive: caseSensitive);
  if (path == null) return root(uri);
  for (final (prefix, build, caseSensitive: sensitive) in scopes) {
    if (prefix.length > path.length) continue;
    var matches = true;
    for (var i = 0; i < prefix.length && matches; i++) {
      matches =
          prefix[i].startsWith(':') ||
          partMatches(prefix[i], path[i], sensitive);
    }
    if (matches) return build(uri);
  }
  return root(uri);
}
