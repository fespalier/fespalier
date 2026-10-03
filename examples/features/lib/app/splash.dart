import 'package:flutter/widgets.dart';

/// Shown while startup() runs, and in its place when it throws. It is built before the app, so
/// there is no Theme, Localizations or ProviderScope above it: plain widgets only. It can ask
/// for `error`, `stackTrace` and `retry`, which are null while startup() is still running.
class Splash extends StatelessWidget {
  const Splash({super.key, this.error, this.retry});

  final Object? error;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) {
    final failed = error != null;
    return ColoredBox(
      color: const Color(0xFFFFFFFF),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              failed ? "Couldn't restore the session: $error" : 'Starting…',
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
}
