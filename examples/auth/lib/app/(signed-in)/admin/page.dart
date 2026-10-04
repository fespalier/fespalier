import 'package:flutter/material.dart';

class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Admin')),
    body: const Center(child: Text('Only an admin sees this.')),
  );
}
