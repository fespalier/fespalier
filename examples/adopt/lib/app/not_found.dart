import 'package:adopt/screens.dart';
import 'package:flutter/widgets.dart';

/// What `AppRoutes.notFound(state.uri)` shows: the host router's `errorBuilder` forwards every
/// URL nothing matches here, inside `/shop` or out of it.
class NotFoundPage extends StatelessWidget {
  const NotFoundPage({super.key, required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) => MissingView(uri: uri);
}
