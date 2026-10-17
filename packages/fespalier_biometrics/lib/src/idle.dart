import 'package:fespalier/fespalier.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'unlock.dart';

/// The idle lock's tick (since 0.19.0): a signal that never fires by itself, like `fespalier_cratestack`'s
/// `syncTicker`. The app fires it from its own `Timer.periodic` (at most `idleTimeout / 4` apart,
/// stopped while the app is hidden), `ref.read(biometricIdleTicker.notifier).fire()`. On a tick
/// `BiometricUnlock` locks if the unlock has been idle for `BiometricPolicy.idleTimeout`. This package
/// starts no timer, so the period, the pause and the test (`fire()`) are the app's.
final biometricIdleTicker = NotifierProvider.autoDispose<RefetchSignal, int>(
  RefetchSignal.new,
);

/// Records activity for the idle lock and swallows the first touch after the limit (since 0.19.0).
///
/// Put it above the navigator, in `MaterialApp.router(builder: (context, child) => BiometricActivity(child: child!))`.
/// Every pointer down, pointer signal (a wheel) and key event that reaches it calls
/// `BiometricUnlock.touch`, which writes a field: no rebuild per touch. Key events are only seen when
/// a widget below has the focus, and they are not handled here.
///
/// When the idle limit has already passed (by the clock, so it is right even if the ticker is late or
/// absent) the first touch is **absorbed**: it is hit-tested to this widget and not to the page, so the
/// button under the finger is not pressed, and it locks. Pointer routes are fixed when a touch is
/// hit-tested, so a lock from the pointer-down callback alone would let that touch through.
/// Without an `idleTimeout` it only passes everything on.
class BiometricActivity extends ConsumerWidget {
  /// Wraps [child].
  const BiometricActivity({super.key, required this.child});

  /// The app, usually the `child` of `MaterialApp.router`'s `builder`.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlock = ref.read(biometricUnlock.notifier);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, _) {
        unlock.touch();
        return KeyEventResult.ignored;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => unlock.touch(),
        onPointerSignal: (_) => unlock.touch(),
        child: _IdleGate(unlock: unlock, child: child),
      ),
    );
  }
}

class _IdleGate extends SingleChildRenderObjectWidget {
  const _IdleGate({required this.unlock, required super.child});

  final BiometricUnlock unlock;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderIdleGate(unlock);

  @override
  void updateRenderObject(BuildContext context, _RenderIdleGate renderObject) {
    renderObject.unlock = unlock;
  }
}

/// Takes the touch for itself once the unlock is idle, and locks on it. Nothing else: no ticker, no paint.
class _RenderIdleGate extends RenderProxyBox {
  _RenderIdleGate(this.unlock);

  BiometricUnlock unlock;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (size.contains(position) && unlock.isIdle()) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return super.hitTest(result, position: position);
  }

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    // A box that is hit through its child is a target too, so this runs for every touch: only the
    // ones that came after the limit (the ones `hitTest` took) lock.
    if ((event is PointerDownEvent || event is PointerSignalEvent) &&
        unlock.isIdle()) {
      unlock.lock();
    }
  }
}
