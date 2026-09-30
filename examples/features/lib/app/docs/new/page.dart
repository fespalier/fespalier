import 'package:flutter/material.dart';

/// A static sibling of the catch-all: `/docs/new` is tried before `/docs/*rest`.
class NewDocPage extends StatelessWidget {
  const NewDocPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('New doc');
}
