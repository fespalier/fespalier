// `smokeTestRoute(guidelines:)` (since 0.16.0): what `fespalier: test: a11y:` makes `fsp test` pass.
// Flutter's own guidelines run once the page is on screen, on the fake clock, with semantics on.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers after 700 ms, as the shop's fake API does: the guidelines must wait for it.
final slowProvider = FutureProvider.autoDispose<String>((ref) async {
  await Future<void>.delayed(const Duration(milliseconds: 700));
  return 'loaded';
});

/// A page that meets every guideline: a labelled 48x48 button and dark text on white.
class GoodPage extends ConsumerWidget {
  const GoodPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(slowProvider)
      .when(
        data: (text) => Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(text),
                IconButton(
                  tooltip: 'Add',
                  icon: const Icon(Icons.add),
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
        loading: () => const Scaffold(body: Text('loading')),
        error: (e, _) => Text('$e'),
      );
}

/// A tap target of 20x20 with no label.
class SmallPage extends StatelessWidget {
  const SmallPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: GestureDetector(
        onTap: () {},
        child: const SizedBox(width: 20, height: 20, child: Placeholder()),
      ),
    ),
  );
}

/// Light grey text on white.
class PalePage extends StatelessWidget {
  const PalePage({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Text('pale', style: TextStyle(color: Color(0xFFEEEEEE))),
    ),
  );
}

GoRouter routerFor(Widget page) => GoRouter(
  routes: [GoRoute(path: '/', builder: (_, _) => page)],
);

/// What [smokeTestRoute] fails with for [page] under [guidelines], or null when it passes.
Future<String?> failureOf(
  WidgetTester tester,
  Widget page,
  List<AccessibilityGuideline> guidelines,
) async {
  try {
    await smokeTestRoute(
      tester,
      '/',
      routerFor(page),
      page: find.byWidget(page),
      guidelines: guidelines,
    );
  } on TestFailure catch (e) {
    return e.message;
  }
  return null;
}

/// How many semantics handles are open: `testWidgets` holds one, and it must not grow.
int handles(WidgetTester tester) =>
    tester.binding.debugOutstandingSemanticsHandles;

void main() {
  testWidgets('routeA11yGuidelines is every guideline fsp test knows', (
    tester,
  ) async {
    expect(routeA11yGuidelines, hasLength(4));
    expect(
      routeA11yGuidelines,
      containsAll([
        androidTapTargetGuideline,
        iOSTapTargetGuideline,
        labeledTapTargetGuideline,
        textContrastGuideline,
      ]),
    );
  });

  testWidgets('a page that meets them passes after a 700 ms fake delay', (
    tester,
  ) async {
    final before = handles(tester);
    await smokeTestRoute(
      tester,
      '/',
      routerFor(const GoodPage()),
      page: find.text('loaded'),
      guidelines: routeA11yGuidelines,
    );
    expect(handles(tester), before);
  });

  testWidgets('a 20x20 target without a label fails tap targets and labels', (
    tester,
  ) async {
    final before = handles(tester);
    expect(
      await failureOf(tester, const SmallPage(), [androidTapTargetGuideline]),
      contains('expected tap target size of at least Size(48.0, 48.0)'),
    );
    expect(
      await failureOf(tester, const SmallPage(), [iOSTapTargetGuideline]),
      contains('expected tap target size of at least Size(44.0, 44.0)'),
    );
    expect(
      await failureOf(tester, const SmallPage(), [labeledTapTargetGuideline]),
      contains('Tappable widgets should have a semantic label'),
    );
    expect(handles(tester), before);
  });

  testWidgets('pale text fails the contrast guideline', (tester) async {
    final before = handles(tester);
    expect(
      await failureOf(tester, const PalePage(), [textContrastGuideline]),
      contains('Expected contrast ratio of at least 4.5'),
    );
    expect(handles(tester), before);
  });

  testWidgets('only the guidelines in the list are checked', (tester) async {
    // Contrast is not on, so pale text passes, and so does a small target that has a label.
    expect(
      await failureOf(tester, const PalePage(), [
        androidTapTargetGuideline,
        iOSTapTargetGuideline,
        labeledTapTargetGuideline,
      ]),
      isNull,
    );
    expect(
      await failureOf(tester, const SmallPage(), [textContrastGuideline]),
      isNull,
    );
  });

  testWidgets('with no guidelines nothing is checked and no handle is taken', (
    tester,
  ) async {
    final before = handles(tester);
    expect(await failureOf(tester, const SmallPage(), const []), isNull);
    expect(await failureOf(tester, const PalePage(), const []), isNull);
    expect(handles(tester), before);
  });

  testWidgets('turns semantics on for the check when the test has them off', (
    tester,
  ) async {
    expect(handles(tester), 0);
    final message = await failureOf(tester, const SmallPage(), [
      labeledTapTargetGuideline,
    ]);
    // Without a semantics tree there would be nothing to evaluate: a failure proves there was.
    expect(message, contains('Tappable widgets should have a semantic label'));
    expect(handles(tester), 0);
  }, semanticsEnabled: false);

  testWidgets('a page that never comes still fails as before', (tester) async {
    final before = handles(tester);
    TestFailure? failure;
    try {
      await smokeTestRoute(
        tester,
        '/missing',
        routerFor(const PalePage()),
        timeout: const Duration(seconds: 1),
        guidelines: routeA11yGuidelines,
      );
    } on TestFailure catch (e) {
      failure = e;
    }
    expect(
      failure?.message,
      contains('The page of /missing is not on screen after 1000 ms'),
    );
    // A test that failed while waiting does not leave the handle open.
    expect(handles(tester), before);
  });
}
