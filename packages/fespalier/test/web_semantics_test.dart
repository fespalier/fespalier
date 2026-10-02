// `ensureWebSemantics`, which the generated `AppRoutes.mount()` calls when the pubspec says
// `semantics_ids: true`: the semantics tree is on in a web build for a driver like Maestro, and
// off the web nothing changes.
import 'package:fespalier/fespalier.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// The handles the semantics binding holds; a test binding may hold some of its own.
int handles() => SemanticsBinding.instance.debugOutstandingSemanticsHandles;

void main() {
  testWidgets('off the web it takes no semantics handle', (tester) async {
    final before = handles();
    ensureWebSemantics();
    expect(handles(), before);
  });

  testWidgets(
    'on the web it takes one handle, once, and a reset gives it back',
    (tester) async {
      final before = handles();
      try {
        ensureWebSemantics(isWeb: true);
        expect(handles(), before + 1);
        expect(SemanticsBinding.instance.semanticsEnabled, isTrue);

        // A second call takes no second handle.
        ensureWebSemantics(isWeb: true);
        expect(handles(), before + 1);

        debugResetWebSemantics();
        expect(handles(), before);
      } finally {
        debugResetWebSemantics();
      }
    },
  );

  testWidgets('a reset with nothing on does nothing', (tester) async {
    final before = handles();
    debugResetWebSemantics();
    expect(handles(), before);
  });
}
