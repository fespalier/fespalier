import 'package:flutter/material.dart';
import 'package:tabs/app.g.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Profile'),
            TextButton(
              onPressed: () => const EditProfileRoute().go(context),
              child: const Text('Edit profile'),
            ),
            TextButton(
              onPressed: () => const SettingsRoute().go(context),
              child: const Text('Settings'),
            ),
          ],
        ),
      );
}
