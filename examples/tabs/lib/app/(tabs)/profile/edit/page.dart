import 'package:flutter/material.dart';

/// Full screen: `navigator.dart` next to this file puts it on the root
/// navigator, so the tab layout's navigation bar is not around it.
class EditProfilePage extends StatelessWidget {
  const EditProfilePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Edit profile')),
        body: const Center(child: Text('Editing your profile')),
      );
}
