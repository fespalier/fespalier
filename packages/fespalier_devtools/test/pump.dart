// What the widget tests share: the extension on a screen as big as DevTools' panel, against a
// scripted app.
import 'package:fespalier_devtools/src/ui/fespalier_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';

/// Shows [FespalierApp] for [client] and lets what it asked for arrive.
Future<void> pumpApp(WidgetTester tester, FakeFespalierClient client) async {
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: FespalierApp(client: client)));
  await settle(tester);
}

/// Lets answers and events arrive, and the frames they ask for run.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pumpAndSettle();
}

/// Opens the tab called [name].
Future<void> openTab(WidgetTester tester, String name) async {
  final tab = find.widgetWithText(Tab, name);
  // The tab bar scrolls: in a narrow panel the tab may be off to the side.
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}
