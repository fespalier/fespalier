/// Notification taps open typed routes (since 0.13.0): a cold start and a tap while the app runs
/// become a navigation marked `source=notification`, through the adapter in
/// `package:fespalier_push/fespalier_adapter.dart`. The push SDK is the app's: it gives a
/// [PushSource], and Firebase Messaging is a recipe in the fespalier-routing skill.
library;

export 'src/configure.dart' show FespalierPush;
export 'src/message.dart' show PushMessage;
export 'src/permission.dart' show PushPermission;
export 'src/providers.dart'
    show
        pushPermission,
        pushReceived,
        pushSource,
        pushToken,
        pushTokenRevoked,
        requestPushPermission;
export 'src/route.dart' show PushOpen, PushRoute, PushTarget, linkRoute;
export 'src/source.dart' show PushSource;
export 'src/token.dart' show PushToken, PushTokenKind, PushTokenRevoked;
export 'src/telemetry.dart' show FespalierPushConventions;
