import 'package:fespalier/fespalier.dart' show NavigationSource;

/// What opened the app from the home screen (since 0.18.0): a shortcut item or a widget tap. A
/// sealed class, so the app's `route:` can be an exhaustive `switch` over the two kinds.
///
/// Equality ignores [raw]: two actions are the same when they name the same shortcut type or the
/// same widget URI, which is how the startup de-duplicates a cold start.
sealed class LaunchAction {
  /// Made by a source. [raw] is the vendor's own object, for the app's mapping only.
  const LaunchAction({this.raw});

  /// The vendor's object (a `ShortcutItem`'s launch data, a widget's intent), for the app's
  /// [LaunchRoute] only. The package never reads it, and it is not part of equality.
  final Object? raw;

  /// The `NavigationSource` value a navigation this action starts is marked with: `shortcut` or
  /// `widget` (`fespalier.navigation.source`).
  String get source;
}

/// A home-screen shortcut was chosen (since 0.18.0), as quick_actions reports it: its item type.
final class ShortcutAction extends LaunchAction {
  /// A shortcut of [type] (the `type` of its `ShortcutItem`), with the vendor's [raw] object.
  const ShortcutAction(this.type, {super.raw});

  /// The shortcut item's type, the string the app gave it in `setShortcutItems`. The app maps it
  /// with a `switch` on its own constants: a shortcut is untrusted input (any app can start one).
  final String type;

  @override
  String get source => NavigationSource.shortcut;

  @override
  bool operator ==(Object other) =>
      other is ShortcutAction && other.type == type;

  @override
  int get hashCode => Object.hash(ShortcutAction, type);

  @override
  String toString() => 'ShortcutAction($type)';
}

/// A home-screen widget was tapped (since 0.18.0): the URI the widget opened the app with.
final class WidgetAction extends LaunchAction {
  /// A tap on a widget that opened the app at [uri], with the vendor's [raw] object.
  const WidgetAction(this.uri, {super.raw});

  /// The URI the widget opened the app with (the launch intent's data, or the widget's URL). Its
  /// path is the in-app location the app maps, through [widgetLinkRoute] or its own `switch`.
  final Uri uri;

  @override
  String get source => NavigationSource.widget;

  @override
  bool operator ==(Object other) => other is WidgetAction && other.uri == uri;

  @override
  int get hashCode => Object.hash(WidgetAction, uri);

  /// The scheme only: a path or a query may carry an id, and a log line must never hold one.
  @override
  String toString() => 'WidgetAction(${uri.scheme})';
}
