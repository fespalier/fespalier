import 'package:fespalier_push/fespalier_push.dart';
import 'package:fespalier_push/testing.dart';
import 'package:flutter/foundation.dart';

import 'app.g.dart';

/// The push provider of this demo: a fake the debug buttons on the home page drive. A real app
/// writes a `PushSource` over its vendor SDK (the fespalier-routing skill has the Firebase
/// Messaging recipe) and hands that to `FespalierPush.configure` instead.
final FakePushSource demoPush = FakePushSource(token: 'demo-token-1');

/// Where a tap goes: the payload's `link` key, kept only when it is an in-app path (or an https
/// URL on the app's host) that one of the app's routes matches. Anything else opens the app and
/// navigates nowhere.
final PushRoute pushRoute = linkRoute(
  hosts: {'plugins.example.com'},
  matches: (uri) => AppRoutes.matchUrl(uri) != null,
);

/// The tokens `main()` was given, newest last; a real app sends it to its backend here.
final List<String> sentTokens = [];

/// What `FespalierPush.configure(onToken:)` calls.
void sendToken(String token) {
  sentTokens.add(token);
  debugPrint('push token: $token');
}
