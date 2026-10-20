import 'package:adopt/screens.dart';
import 'package:flutter/widgets.dart';

/// What `AppRoutes.errorPage` shows for a URL nothing matches here, inside `/shop` or out of it: the
/// host router's `errorBuilder` forwards it (since 0.21.0; a failed guard shows its error.dart instead).
class NotFoundPage extends StatelessWidget {
  const NotFoundPage({super.key, required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) => MissingView(uri: uri);
}
