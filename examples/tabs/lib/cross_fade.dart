import 'package:flutter/material.dart';

/// A branch container for a tab layout that cross-fades between tabs.
///
/// Every branch's navigator stays in the tree (that is what keeps a tab's state
/// and stack while you look at another one), but only the current tab, and the
/// one it replaces while it fades out, is painted: the others are `Offstage`.
class CrossFadeContainer extends StatefulWidget {
  const CrossFadeContainer({
    super.key,
    required this.currentIndex,
    required this.children,
    this.duration = const Duration(milliseconds: 200),
  });

  final int currentIndex;

  /// The branches' navigators, in the tab layout's order.
  final List<Widget> children;

  final Duration duration;

  @override
  State<CrossFadeContainer> createState() => _CrossFadeContainerState();
}

class _CrossFadeContainerState extends State<CrossFadeContainer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  );
  int? _leaving;

  @override
  void didUpdateWidget(CrossFadeContainer old) {
    super.didUpdateWidget(old);
    if (old.currentIndex != widget.currentIndex) {
      _leaving = old.currentIndex;
      _fade.forward(from: 0).whenComplete(() {
        if (mounted) setState(() => _leaving = null);
      });
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          for (final (i, navigator) in widget.children.indexed)
            Offstage(
              offstage: i != widget.currentIndex && i != _leaving,
              child: TickerMode(
                enabled: i == widget.currentIndex,
                child: IgnorePointer(
                  ignoring: i != widget.currentIndex,
                  child: FadeTransition(
                    opacity: i == widget.currentIndex
                        ? _fade
                        : ReverseAnimation(_fade),
                    child: navigator,
                  ),
                ),
              ),
            ),
        ],
      );
}
