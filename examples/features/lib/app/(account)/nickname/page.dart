import 'package:features/app.g.dart';
import 'package:features/nicknames.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// A form on an action: `NicknameRoute.useForm` gives a typed field per field of the action's
/// input, errors per field, a submit that is null while the save runs, and `reset`. The
/// title shows `profile` as the save will leave it from the moment it starts.
///
/// A real hook: the page is a [HookConsumerWidget].
class NicknamePage extends HookConsumerWidget {
  const NicknamePage({super.key, required this.profile});

  /// data.dart's, by type: with the optimistic patch while a save is in flight.
  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = NicknameRoute.useForm(ref, data: profile);
    final f = form.fields;
    return Scaffold(
      body: Column(
        children: [
          Text('Hello ${profile.nickname}'),
          TextField(
            controller: f.nickname.controller,
            decoration: InputDecoration(
              labelText: 'Nickname',
              errorText: f.nickname.error,
            ),
          ),
          TextField(
            controller: f.age.controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Age',
              errorText: f.age.error,
            ),
          ),
          CheckboxListTile(
            title: const Text('Newsletter'),
            value: f.newsletter.value,
            onChanged: f.newsletter.didChange,
          ),
          if (form.error case final e?) Text('$e'),
          FilledButton(
            // Null while the save runs: the button is disabled.
            onPressed: form.onSubmit,
            child: Text(form.isPending ? 'Saving...' : 'Save'),
          ),
          TextButton(
            onPressed: form.isDirty ? form.reset : null,
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }
}
