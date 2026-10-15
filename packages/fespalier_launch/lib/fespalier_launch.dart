/// Shortcut and home-screen widget taps open typed routes (since 0.18.0): a cold start and an
/// action while the app runs become a navigation marked `source=shortcut` or `source=widget`,
/// through the adapter in `package:fespalier_launch/fespalier_adapter.dart`. The plugins are the
/// app's: it gives a [LaunchSource] for each, and quick_actions and home_widget are recipes in the
/// fespalier-routing skill, not dependencies of this package.
library;

export 'src/action.dart' show LaunchAction, ShortcutAction, WidgetAction;
export 'src/configure.dart' show FespalierLaunch;
export 'src/route.dart'
    show LaunchOpen, LaunchRoute, LaunchTarget, widgetLinkRoute;
export 'src/source.dart' show LaunchSource;
export 'src/telemetry.dart' show FespalierLaunchConventions;
