import 'package:flutter/widgets.dart';

/// Shown while startup() reads the bundled catalogs, and in its place when a file is missing. It is
/// built before the app, so there is no Theme, Localizations or ProviderScope above it, and no
/// translation either: plain widgets only.
class Splash extends StatelessWidget {
  const Splash({super.key, this.error, this.retry});

  final Object? error;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFFFFFFFF),
    child: Center(
      child: GestureDetector(
        onTap: retry,
        child: Text(
          error == null ? '...' : 'Could not read the texts: $error',
          textDirection: TextDirection.ltr,
          style: const TextStyle(color: Color(0xFF000000), fontSize: 16),
        ),
      ),
    ),
  );
}
