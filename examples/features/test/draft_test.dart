// A streaming action (since 0.25.0): docs/new/action.dart's draft() returns a Stream, so the page
// shows the text as it grows, stops it, and the run ends when the page goes away. No test waits for
// real time: the writer is one the test feeds through a StreamController.
import 'dart:async';

import 'package:features/app.g.dart';
import 'package:features/drafts.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A writer the test feeds: one controller per draft, and whether its stream was cancelled.
class FedWriter implements DraftWriter {
  final runs = <StreamController<String>>[];
  final topics = <String>[];
  var cancels = 0;

  @override
  Stream<String> write(String topic) {
    topics.add(topic);
    final controller = StreamController<String>(onCancel: () => cancels++);
    runs.add(controller);
    return controller.stream;
  }
}

void main() {
  Future<(GoRouter, FedWriter)> boot(WidgetTester tester) async {
    final writer = FedWriter();
    final router = AppRoutes.router(initialLocation: '/docs/new');
    await pumpRouter(
      tester,
      router,
      overrides: [draftWriterProvider.overrideWithValue(writer)],
    );
    return (router, writer);
  }

  testWidgets('the draft grows as it comes, and Use draft puts it in the doc', (
    tester,
  ) async {
    final (_, writer) = await boot(tester);
    await tester.enterText(find.byType(TextField), 'otters');
    await tester.tap(find.text('Draft'));
    await tester.pump();
    expect(writer.topics, ['otters']);
    expect(find.text('Stop'), findsOneWidget);
    writer.runs.single.add('A');
    await tester.pump();
    expect(find.text('A'), findsOneWidget);
    writer.runs.single.add('A short doc about otters');
    await tester.pump();
    expect(find.text('A short doc about otters'), findsOneWidget);
    await writer.runs.single.close();
    await tester.pump();
    expect(find.text('Stop'), findsNothing);
    await tester.tap(find.text('Use draft'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'A short doc about otters',
    );
  });

  testWidgets('an empty topic is refused before the stream starts', (
    tester,
  ) async {
    final (_, writer) = await boot(tester);
    await tester.tap(find.text('Draft'));
    await tester.pump();
    expect(writer.runs, isEmpty);
    expect(find.text('Type what the doc is about first'), findsOneWidget);
  });

  testWidgets('Stop cancels the stream and keeps what arrived', (tester) async {
    final (_, writer) = await boot(tester);
    await tester.enterText(find.byType(TextField), 'otters');
    await tester.tap(find.text('Draft'));
    await tester.pump();
    writer.runs.single.add('A short');
    await tester.pump();
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(writer.cancels, 1);
    expect(find.text('A short'), findsOneWidget);
    expect(find.text('Use draft'), findsOneWidget);
  });

  testWidgets('leaving the page stops the draft', (tester) async {
    final (router, writer) = await boot(tester);
    await tester.enterText(find.byType(TextField), 'otters');
    await tester.tap(find.text('Draft'));
    await tester.pump();
    writer.runs.single.add('A');
    await tester.pump();
    router.go('/docs');
    await tester.pumpAndSettle();
    // What is typed is asked about first (leave.dart); discarding it lets the page go.
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Docs index'), findsOneWidget);
    expect(writer.cancels, 1);
  });
}
