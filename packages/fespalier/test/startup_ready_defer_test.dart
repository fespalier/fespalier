// Without a splash.dart an async ready() defers the first frame too (since 0.12.0), so the native
// splash stays. Alone in its file, like startup_defer_test.dart: the binding remembers that a frame
// was sent.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('with no splash the first frame waits for ready()', (
    tester,
  ) async {
    final binding = tester.binding;
    final done = Completer<void>();
    await tester.pumpWidget(
      StartupGate(
        ready: (container) => done.future,
        router: () => GoRouter(
          routes: [GoRoute(path: '/', builder: (_, _) => const Text('home'))],
        ),
        app: (router) => MaterialApp.router(routerConfig: router),
      ),
    );
    expect(binding.sendFramesToEngine, isFalse);
    expect(find.text('home'), findsNothing);

    done.complete();
    await tester.pumpAndSettle();
    expect(binding.sendFramesToEngine, isTrue);
    expect(find.text('home'), findsOneWidget);
  });
}
