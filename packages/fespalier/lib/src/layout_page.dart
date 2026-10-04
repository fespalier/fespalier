import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'platform_page.dart';
import 'transitions.dart';

/// The page the generated router builds for a `layout.dart`, the way go_router
/// builds one for a bare `builder`, but with a [restorationId] that is the
/// same after the app restarts.
///
/// go_router keys the page of a `ShellRoute` or `StatefulShellRoute` by the
/// route object's `hashCode`, and uses that as the page's restoration id. It
/// changes with every launch, so what is saved under it (the tabs and their
/// stacks, and the state of the pages in a layout's navigator) is never found
/// again. A stable id from the layout's folder fixes that.
///
/// A Material page, or a Cupertino one inside a `CupertinoApp`.
///
/// Named by the pattern of the layout's section (`Transitions.pageName`, set by the generated
/// `namedPage`, since 0.9.0), so a `NavigatorObserver` sees `/` or `/shop` for a shell; outside
/// `namedPage` it is go_router's own name, as before.
Page<void> layoutPage(
  BuildContext context,
  GoRouterState state,
  String restorationId,
  Widget child,
) {
  final name = Transitions.pageName ?? state.name ?? state.path;
  final arguments = <String, String>{
    ...state.pathParameters,
    ...state.uri.queryParameters,
  };
  return platformPage(
    context,
    key: ValueKey<String>(restorationId),
    name: name,
    arguments: arguments,
    restorationId: restorationId,
    child: child,
  );
}
