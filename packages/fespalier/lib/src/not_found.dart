import 'package:flutter/widgets.dart';

import 'route_match.dart';

/// A `not_found.dart` below the root: the URL prefix of its folder (a segment
/// starting with `:` matches anything) and the widget to show.
typedef NotFoundScope = (List<String> prefix, Widget Function(Uri uri) build);

/// The generated `notFound(uri)`: the not-found view of the deepest folder that
/// [uri] is under, or [root] when none is.
///
/// [scopes] are ordered nearest first. [base] is where the tree is mounted.
/// With [caseSensitive] off (the `case_sensitive: false` config), `/Products` is
/// under `products/`.
Widget nearestNotFound(
  Uri uri,
  String base,
  List<NotFoundScope> scopes,
  Widget Function(Uri uri) root, {
  bool caseSensitive = true,
}) {
  bool same(String a, String b) =>
      caseSensitive ? a == b : a.toLowerCase() == b.toLowerCase();
  final path = pathBelow(uri, base, caseSensitive: caseSensitive);
  if (path == null) return root(uri);
  for (final (prefix, build) in scopes) {
    if (prefix.length > path.length) continue;
    var matches = true;
    for (var i = 0; i < prefix.length && matches; i++) {
      matches = prefix[i].startsWith(':') || same(prefix[i], path[i]);
    }
    if (matches) return build(uri);
  }
  return root(uri);
}
