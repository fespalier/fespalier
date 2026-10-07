// A back handler that declines (since 0.11.0): on the first page of a navigator the back is not
// trapped by the page's PopScope. A router that can pop pops (and `leave()` is asked); one that
// cannot ends the app.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final List<String> asked = [];
final List<String> platform = [];

class Declines extends StatefulWidget {
  const Declines({super.key, required this.child});

  final Widget child;

  @override
  State<Declines> createState() => _DeclinesState();
}

class _DeclinesState extends State<Declines> {
  VoidCallback? _off;

  @override
  void initState() {
    super.initState();
    _off = LeaveScope.maybeOf(context)?.onBack(() => false);
  }

  @override
  void dispose() {
    _off?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

GoRoute page(String path, String label) => GoRoute(
  path: path,
  onExit: (context, state) =>
      leaveExit(context, state, '$label/leave.dart', (ref, page) {
        asked.add(label);
        return true;
      }),
  pageBuilder: (context, state) => MaterialPage<void>(
    key: state.pageKey,
    child: leaveScope(state, Declines(child: Scaffold(body: Text(label)))),
  ),
);

Future<GoRouter> boot(WidgetTester tester, String initial) async {
  final router = GoRouter(
    initialLocation: initial,
    routes: [page('/a', 'a'), page('/b', 'b')],
  );
  await tester.pumpWidget(
    ProviderScope(child: MaterialApp.router(routerConfig: router)),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  setUp(() {
    asked.clear();
    platform.clear();
  });

  Future<void> record(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platform.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  testWidgets('on the only page, a declined back ends the app', (tester) async {
    await record(tester);
    await boot(tester, '/a');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(platform, contains('SystemNavigator.pop'));
  });

  testWidgets('on a page above another, a declined back pops, and asks', (
    tester,
  ) async {
    await record(tester);
    final router = await boot(tester, '/a');
    unawaited(router.push<void>('/b'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('a'), findsOneWidget);
    expect(asked, ['b']);
    expect(platform, isNot(contains('SystemNavigator.pop')));
  });
}
