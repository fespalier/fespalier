import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// The page go_router builds for a bare `builder`: a Material page, or a
/// Cupertino one inside a `CupertinoApp`, with the [arguments] and
/// [restorationId] go_router would give it.
///
/// Used where the generated router builds a page itself, because the page's
/// key is not go_router's own (`layoutPage`, `remountPage`).
Page<void> platformPage(
  BuildContext context, {
  required LocalKey key,
  required String? name,
  required Map<String, String> arguments,
  required String restorationId,
  required Widget child,
}) {
  if (context.findAncestorWidgetOfExactType<CupertinoApp>() != null) {
    return CupertinoPage<void>(
      key: key,
      name: name,
      arguments: arguments,
      restorationId: restorationId,
      child: child,
    );
  }
  return MaterialPage<void>(
    key: key,
    name: name,
    arguments: arguments,
    restorationId: restorationId,
    child: child,
  );
}
