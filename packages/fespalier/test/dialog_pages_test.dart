import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Navigator that shows [pages]; removed pages are collected in [removed]
/// and dropped, the way go_router reacts to a pop.
class _Stack extends StatefulWidget {
  const _Stack(this.pages, this.removed);
  final List<Page<void>> pages;
  final List<Page<void>> removed;

  @override
  State<_Stack> createState() => _StackState();
}

class _StackState extends State<_Stack> {
  late List<Page<void>> pages = widget.pages;

  @override
  Widget build(BuildContext context) => Navigator(
    pages: pages,
    onDidRemovePage: (page) {
      widget.removed.add(page as Page<void>);
      setState(() => pages = [...pages]..remove(page));
    },
  );
}

const _base = ValueKey('base');
const _top = ValueKey('top');

Page<void> _basePage() => Transitions.material(_base, const Text('below'));

void main() {
  Future<List<Page<void>>> pump(
    WidgetTester tester,
    Page<void> top, {
    bool material = true,
  }) async {
    final removed = <Page<void>>[];
    final stack = _Stack([_basePage(), top], removed);
    await tester.pumpWidget(
      material
          ? MaterialApp(home: stack)
          : WidgetsApp(
              color: const Color(0xFFFFFFFF),
              builder: (context, _) => stack,
            ),
    );
    await tester.pumpAndSettle();
    return removed;
  }

  testWidgets('dialog shows over the previous page and pops with its barrier', (
    tester,
  ) async {
    final removed = await pump(
      tester,
      Transitions.dialog(_top, const Center(child: Text('dialog'))),
    );
    expect(find.text('dialog'), findsOneWidget);
    expect(find.text('below'), findsOneWidget);
    final route = ModalRoute.of(tester.element(find.text('dialog')))!;
    expect(route, isA<DialogRoute<void>>());
    expect(route.settings, isA<Page<void>>());
    expect(route.opaque, isFalse);

    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.text('dialog'), findsNothing);
    expect(find.text('below'), findsOneWidget);
    expect(removed.map((p) => p.key), [_top]);
  });

  testWidgets('a dialog can refuse to be dismissed by its barrier', (
    tester,
  ) async {
    final removed = await pump(
      tester,
      Transitions.dialog(
        _top,
        const Center(child: Text('dialog')),
        barrierDismissible: false,
      ),
    );
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.text('dialog'), findsOneWidget);
    expect(removed, isEmpty);

    // Programmatic pops still work.
    Navigator.of(tester.element(find.text('dialog'))).pop();
    await tester.pumpAndSettle();
    expect(removed.map((p) => p.key), [_top]);
  });

  testWidgets('a dialog does not need MaterialLocalizations', (tester) async {
    await pump(
      tester,
      Transitions.dialog(_top, const Center(child: Text('dialog'))),
      material: false,
    );
    expect(find.text('dialog'), findsOneWidget);
  });

  testWidgets('sheet is a modal bottom sheet at the bottom of the screen', (
    tester,
  ) async {
    final removed = await pump(
      tester,
      Transitions.sheet(
        _top,
        const SizedBox(height: 100, child: Text('sheet')),
        showDragHandle: true,
      ),
    );
    expect(find.text('sheet'), findsOneWidget);
    expect(find.text('below'), findsOneWidget);
    expect(
      ModalRoute.of(tester.element(find.text('sheet'))),
      isA<ModalBottomSheetRoute<void>>(),
    );
    expect(find.byType(BottomSheet), findsOneWidget);
    // At the bottom: below the middle of the 600 px screen.
    expect(tester.getCenter(find.text('sheet')).dy, greaterThan(400));

    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
    expect(removed.map((p) => p.key), [_top]);
  });

  testWidgets('a sheet that is not dismissible stays', (tester) async {
    final removed = await pump(
      tester,
      Transitions.sheet(
        _top,
        const Text('sheet'),
        isDismissible: false,
        enableDrag: false,
      ),
    );
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsOneWidget);
    expect(removed, isEmpty);
  });

  testWidgets('fullscreenDialog is a Material page that slides up', (
    tester,
  ) async {
    final page = Transitions.fullscreenDialog(_top, const Text('full'));
    expect(page, isA<MaterialPage<void>>());
    expect((page as MaterialPage<void>).fullscreenDialog, isTrue);
    await pump(tester, page);
    final route = ModalRoute.of(tester.element(find.text('full')))!;
    // The getter is on PageRoute on Flutter 3.32 (the floor), on ModalRoute on newer ones.
    expect((route as PageRoute<Object?>).fullscreenDialog, isTrue);
  });

  test('TabOptions defaults', () {
    const o = TabOptions();
    expect(o.preload, isFalse);
    expect(o.initialLocation, isNull);
    const p = TabOptions(preload: true, initialLocation: '/a');
    expect((p.preload, p.initialLocation), (true, '/a'));
  });
}
