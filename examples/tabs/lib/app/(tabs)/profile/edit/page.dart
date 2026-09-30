import 'package:flutter/material.dart';
import 'package:tabs/profile_draft.dart';

/// `extra` is what `EditProfileRoute().go(context, extra: draft)` passes. It
/// isn't in the URL, so a deep link leaves it null (hence nullable); a restart
/// or a reload gets it back through `extra_codec.dart`.
class EditProfilePage extends StatelessWidget {
  const EditProfilePage({super.key, this.extra});

  final ProfileDraft? extra;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Edit profile'),
            Text('Draft for ${extra?.name ?? 'nobody'}'),
          ],
        ),
      );
}
