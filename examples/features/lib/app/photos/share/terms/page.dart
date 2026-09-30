import 'package:flutter/material.dart';

/// A child of a sheet: it is on the root navigator too, so it opens above the
/// sheet instead of under it, and keeps the nearest transition.dart (the root's).
class TermsPage extends StatelessWidget {
  const TermsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Terms')),
    body: const Center(child: Text('Terms of sharing')),
  );
}
