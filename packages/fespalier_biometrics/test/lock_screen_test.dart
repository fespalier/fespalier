// BiometricLockScreen: it prompts when the button is tapped and never otherwise, it shows the words
// for how the last try ended, and it opens nothing of its own. The package's main library and
// lib/src/ import no Material: this file reads them.
import 'dart:io';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier_biometrics/material.dart';
import 'package:fespalier_biometrics/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts the routes pushed after the first one.
class _Pushes extends NavigatorObserver {
  int count = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) count++;
  }
}

class _Rig {
  _Rig({
    FakeBiometricPrompt? prompt,
    this.messages = const BiometricLockScreenMessages(),
    this.unavailable,
    this.title,
  }) : prompt = prompt ?? FakeBiometricPrompt();

  final FakeBiometricPrompt prompt;
  final BiometricLockScreenMessages messages;
  final WidgetBuilder? unavailable;
  final Widget? title;
  final pushes = _Pushes();
  int unlocked = 0;

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    ProviderScope(
      overrides: biometricTestOverrides(prompt),
      child: MaterialApp(
        navigatorObservers: [pushes],
        home: Scaffold(
          body: BiometricLockScreen(
            reason: 'Unlock your vault',
            onUnlocked: () => unlocked++,
            messages: messages,
            unavailable: unavailable,
            title: title,
          ),
        ),
      ),
    ),
  );
}

VoidCallback? onPressedOf(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byType(FilledButton)).onPressed;

void main() {
  testWidgets('building and rebuilding it never prompts', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.pump(tester);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(rig.prompt.prompts, 0);
    expect(find.text('Unlock'), findsOneWidget);
    expect(rig.unlocked, 0);
  });

  testWidgets('a tap prompts once with the reason and calls onUnlocked', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester);
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(rig.prompt.prompts, 1);
    expect(rig.prompt.reasons, ['Unlock your vault']);
    expect(rig.unlocked, 1);
  });

  testWidgets('a double tap prompts once', (tester) async {
    final rig = _Rig(prompt: FakeBiometricPrompt()..hold());
    await rig.pump(tester);
    await tester.tap(find.text('Unlock'));
    await tester.tap(find.text('Unlock'), warnIfMissed: false);
    await tester.pump();
    expect(rig.prompt.prompts, 1);
    rig.prompt.release();
    await tester.pumpAndSettle();
    expect(rig.prompt.prompts, 1);
    expect(rig.unlocked, 1);
  });

  testWidgets('while the sheet is up the button is disabled', (tester) async {
    final rig = _Rig(prompt: FakeBiometricPrompt()..hold());
    await rig.pump(tester);
    await tester.pumpAndSettle();
    expect(onPressedOf(tester), isNotNull);
    await tester.tap(find.text('Unlock'));
    await tester.pump();
    expect(onPressedOf(tester), isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    rig.prompt.release(BiometricOutcome.cancelled);
    await tester.pumpAndSettle();
    expect(onPressedOf(tester), isNotNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
    'failed shows its message and the button; cancelled shows nothing',
    (tester) async {
      final rig = _Rig(
        prompt: FakeBiometricPrompt(
          outcomes: [BiometricOutcome.failed, BiometricOutcome.cancelled],
        ),
      );
      await rig.pump(tester);
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('Not recognised. Try again.'), findsOneWidget);
      expect(onPressedOf(tester), isNotNull);

      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('Not recognised. Try again.'), findsNothing);
      expect(
        find.text('Too many tries. Unlock your device, then try again.'),
        findsNothing,
      );
      expect(find.text('Unlock'), findsOneWidget);
      expect(rig.prompt.prompts, 2);
      expect(rig.unlocked, 0);
    },
  );

  testWidgets('lockedOut shows its message', (tester) async {
    final rig = _Rig(
      prompt: FakeBiometricPrompt(outcomes: [BiometricOutcome.lockedOut]),
    );
    await rig.pump(tester);
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(
      find.text('Too many tries. Unlock your device, then try again.'),
      findsOneWidget,
    );
    expect(find.text('Unlock'), findsOneWidget);
    expect(rig.unlocked, 0);
  });

  testWidgets('unavailable shows the builder instead of the button', (
    tester,
  ) async {
    final rig = _Rig(
      prompt: FakeBiometricPrompt(available: false),
      unavailable: (context) => const Text('Use your passcode'),
    );
    await rig.pump(tester);
    await tester.pumpAndSettle();
    expect(find.text('Use your passcode'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(rig.prompt.prompts, 0);
  });

  testWidgets('without a builder, the unavailable message', (tester) async {
    final rig = _Rig(prompt: FakeBiometricPrompt(available: false));
    await rig.pump(tester);
    await tester.pumpAndSettle();
    expect(
      find.text('This device cannot check a fingerprint or a face.'),
      findsOneWidget,
    );
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets(
    'a tap that ends unavailable gives way to the message, and a true answer brings the button back',
    (tester) async {
      final rig = _Rig(
        prompt: FakeBiometricPrompt(outcomes: [BiometricOutcome.unavailable]),
      );
      await rig.pump(tester);
      await tester.pumpAndSettle();
      rig.prompt.available = false;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(
        find.text('This device cannot check a fingerprint or a face.'),
        findsOneWidget,
      );
      expect(find.byType(FilledButton), findsNothing);

      rig.prompt.available = true;
      ProviderScope.containerOf(
        tester.element(find.byType(BiometricLockScreen)),
      ).invalidate(biometricAvailable);
      await tester.pumpAndSettle();
      expect(find.byType(FilledButton), findsOneWidget);
      expect(
        find.text('This device cannot check a fingerprint or a face.'),
        findsNothing,
      );
    },
  );

  testWidgets('it opens no dialog, route, menu, sheet or snack bar', (
    tester,
  ) async {
    final rig = _Rig(
      prompt: FakeBiometricPrompt(
        outcomes: [
          BiometricOutcome.failed,
          BiometricOutcome.lockedOut,
          BiometricOutcome.cancelled,
          BiometricOutcome.success,
        ],
      ),
    );
    await rig.pump(tester);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
    }
    expect(rig.prompt.prompts, 4);
    expect(rig.pushes.count, 0);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(PopupMenuButton), findsNothing);
    expect(find.byType(PopupMenuItem), findsNothing);
  });

  testWidgets('the messages and the title can be replaced', (tester) async {
    final rig = _Rig(
      prompt: FakeBiometricPrompt(outcomes: [BiometricOutcome.failed]),
      title: const Text('Coffre'),
      messages: const BiometricLockScreenMessages(
        unlock: 'Deverrouiller',
        failed: 'Non reconnu.',
      ),
    );
    await rig.pump(tester);
    expect(find.text('Coffre'), findsOneWidget);
    await tester.tap(find.text('Deverrouiller'));
    await tester.pumpAndSettle();
    expect(find.text('Non reconnu.'), findsOneWidget);
    expect(find.text('Unlock'), findsNothing);
  });

  test('the main library and lib/src/ import no Material', () {
    final files = [
      File('lib/fespalier_biometrics.dart'),
      File('lib/testing.dart'),
      ...Directory('lib/src')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')),
    ];
    expect(files.length, greaterThan(5));
    final material = RegExp(
      r'''(import|export)\s+['"]package:flutter/(material|cupertino)\.dart['"]''',
    );
    for (final file in files) {
      expect(
        material.hasMatch(file.readAsStringSync()),
        isFalse,
        reason: '${file.path} imports Material or Cupertino',
      );
    }
    expect(
      File('lib/material.dart').readAsStringSync(),
      contains('package:flutter/material.dart'),
    );
  });
}
