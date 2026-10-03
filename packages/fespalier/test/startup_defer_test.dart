// Without a splash.dart an async startup() defers the first frame, so the native splash stays.
// Alone in its file: the binding remembers that a frame was sent, and a test that runs after
// another one in the same file sees a binding that has already shown one.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('with no splash the first frame waits for startup()', (
    tester,
  ) async {
    final binding = tester.binding;
    final done = Completer<void>();
    await tester.pumpWidget(
      StartupGate(
        startup: () => done.future,
        router: () => GoRouter(
          routes: [GoRoute(path: '/', builder: (_, _) => const Text('home'))],
        ),
        app: (router) => MaterialApp.router(routerConfig: router),
      ),
    );
    // The gate asked the engine to hold its first frame, and nothing is on screen yet.
    expect(binding.sendFramesToEngine, isFalse);
    expect(find.text('home'), findsNothing);

    done.complete();
    await tester.pumpAndSettle();
    expect(binding.sendFramesToEngine, isTrue);
    expect(find.text('home'), findsOneWidget);
  });
}
