import 'package:flutter/material.dart';

/// A full-screen dialog: it slides up and its AppBar gets a close button.
class UploadPage extends StatelessWidget {
  const UploadPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Upload photo')),
        body: const Center(child: Text('Pick a file')),
      );
}
