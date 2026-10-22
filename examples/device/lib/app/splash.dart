import 'package:flutter/widgets.dart';

/// Shown while startup() reads the stored session, and in its place when that fails (a locked
/// keychain). It is built before the app, so it has no Theme: plain widgets only.
class Splash extends StatelessWidget {
  const Splash({super.key, this.error, this.retry});

  final Object? error;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFFFFFFFF),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            error == null
                ? 'Restoring your session...'
                : "Couldn't restore your session: $error",
            style: const TextStyle(
              color: Color(0xFF000000),
              fontSize: 16,
              decoration: TextDecoration.none,
            ),
          ),
          if (retry != null)
            GestureDetector(
              onTap: retry,
              child: const Text(
                'Try again',
                style: TextStyle(
                  color: Color(0xFF0000FF),
                  fontSize: 16,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
