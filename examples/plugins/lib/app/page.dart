import 'package:fespalier/fespalier.dart';
import 'package:fespalier_analytics/fespalier_analytics.dart';
import 'package:fespalier_push/fespalier_push.dart';
// Flutter's `Shortcuts` widget is hidden: here `Shortcuts` is the app's shortcut types (launch.dart).
import 'package:flutter/material.dart' hide Shortcuts;
import 'package:plugins/launch.dart';
import 'package:plugins/push.dart';
import 'package:plugins/session.dart';

/// The home page, with the debug buttons that stand in for the system tray: each one is a tap on
/// a notification, delivered through the fake push source, or (since 0.18.0) a home-screen shortcut
/// or widget tap, delivered through the fake launch sources. The last two answer the analytics
/// consent a real app asks for in a banner.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Plugins')),
    body: ListView(
      children: [
        Text(ref.watch(session) ? 'Signed in' : 'Signed out'),
        TextButton(
          onPressed: () => ref.read(session.notifier).set(true),
          child: const Text('Sign in'),
        ),
        TextButton(
          onPressed: () => demoPush.tap(
            const PushMessage(id: 'tap-order', data: {'link': '/orders/42'}),
          ),
          child: const Text('Simulate a tap: order 42'),
        ),
        TextButton(
          onPressed: () => demoPush.tap(
            const PushMessage(id: 'tap-account', data: {'link': '/account'}),
          ),
          child: const Text('Simulate a tap: account'),
        ),
        TextButton(
          onPressed: () => demoPush.tap(
            const PushMessage(
              id: 'tap-evil',
              data: {'link': 'https://evil.example.com/orders/1'},
            ),
          ),
          child: const Text('Simulate a tap: foreign link'),
        ),
        TextButton(
          onPressed: () => demoShortcuts.shortcut(Shortcuts.lastOrder),
          child: const Text('Simulate a shortcut: last order'),
        ),
        TextButton(
          onPressed: () => demoWidget.widget(Uri.parse('plugins:///orders/7')),
          child: const Text('Simulate a widget tap: order 7'),
        ),
        Text('Analytics: ${ref.watch(analyticsConsent).name}'),
        TextButton(
          onPressed: () =>
              ref.read(analyticsConsent.notifier).set(AnalyticsConsent.granted),
          child: const Text('Allow analytics'),
        ),
        TextButton(
          onPressed: () =>
              ref.read(analyticsConsent.notifier).set(AnalyticsConsent.denied),
          child: const Text('Refuse analytics'),
        ),
      ],
    ),
  );
}
