import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:tabs/app.g.dart';
import 'package:tabs/profile_draft.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The settings page, over the tab bar, has the same line: the
            // avatar flies there from the tab that is shown (since 0.8.0).
            const SettingsRoute().hero(
              'avatar',
              child: const CircleAvatar(child: Text('A')),
            ),
            const Text('Profile'),
            TextButton(
              onPressed: () => const EditProfileRoute().go(
                context,
                extra: const ProfileDraft(name: 'Ada'),
              ),
              child: const Text('Edit profile'),
            ),
            TextButton(
              onPressed: () => const SecurityRoute().go(context),
              child: const Text('Security'),
            ),
            TextButton(
              onPressed: () => const SettingsRoute().go(context),
              child: const Text('Settings'),
            ),
          ],
        ),
      );
}
