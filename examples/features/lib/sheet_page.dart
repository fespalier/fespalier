import 'package:flutter/material.dart';

/// The app's own sheet: a `Page` that makes a non-opaque [PopupRoute] with its
/// own scrim and handle. fespalier ships nothing like it; `present.dart` in a
/// route's folder returns it, and the generated router uses the page as it is.
class SheetPage<T> extends Page<T> {
  const SheetPage({super.key, super.restorationId, required this.child});

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) =>
      _SheetRoute<T>(settings: this, child: child);
}

class _SheetRoute<T> extends PopupRoute<T> {
  _SheetRoute({required RouteSettings settings, required this.child})
      : super(settings: settings);

  final Widget child;

  @override
  Color get barrierColor => const Color(0x8A102030);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 250);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          // A width cap, the way a tablet gets one.
          constraints: const BoxConstraints(maxWidth: 640),
          child: SlideTransition(
            position:
                Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
            child: Material(
              color: Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      key: const ValueKey('app-sheet-handle'),
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    child,
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
