import 'package:fespalier_launch/fespalier_launch.dart';
import 'package:fespalier_launch/testing.dart';

import 'app.g.dart';

/// The shortcut types this app gives its home-screen shortcuts. A shortcut is untrusted input (any
/// app can start the launcher with one), so the app maps these by a `switch` on its own constants
/// and nothing else.
abstract final class ShortcutTypes {
  /// "Last order": opens order 42.
  static const String lastOrder = 'last_order';

  /// "Account": opens the account page, behind the session guard.
  static const String account = 'account';
}

/// The shortcut source of this demo: a fake the debug buttons on the home page drive. A real app
/// writes a `LaunchSource` over quick_actions (the fespalier-routing skill has the recipe) and
/// hands that to `FespalierLaunch.configure` instead.
final FakeLaunchSource demoShortcuts = FakeLaunchSource();

/// The widget source of this demo: a fake for a home-screen widget's tap. A real app writes a
/// `LaunchSource` over home_widget, which is also a recipe in the skill.
final FakeLaunchSource demoWidget = FakeLaunchSource();

/// Where a widget's tap goes: the URI `plugins:///orders/7` opens the path `/orders/7`, and only
/// when one of the app's routes matches it. Anything else opens the app and navigates nowhere.
final LaunchRoute _widgetRoute = widgetLinkRoute(
  schemes: {'plugins'},
  hosts: {'plugins.example.com'},
  matches: (uri) => AppRoutes.matchUrl(uri) != null,
);

/// Where a shortcut or a widget tap goes: what `FespalierLaunch.configure(route:)` calls.
LaunchTarget? launchRoute(LaunchAction action) => switch (action) {
  ShortcutAction(type: ShortcutTypes.lastOrder) => LaunchTarget.to(
    const OrderRoute(id: 42),
  ),
  ShortcutAction(type: ShortcutTypes.account) => LaunchTarget.to(
    const AccountRoute(),
  ),
  ShortcutAction() => null,
  WidgetAction() => _widgetRoute(action),
};
