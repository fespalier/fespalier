import 'package:features/app.g.dart';
import 'package:flutter/material.dart';

class SignupNamePage extends StatelessWidget {
  const SignupNamePage({super.key});

  @override
  Widget build(BuildContext context) {
    final flow = SignupSection.flowOf(context);
    final f = flow.fields;
    return Column(
      children: [
        TextField(
          controller: f.name.controller,
          decoration:
              InputDecoration(labelText: 'Name', errorText: f.name.error),
        ),
        Row(
          children: [
            Checkbox(
              value: f.business.value,
              onChanged: f.business.didChange,
            ),
            const Text('For a business'),
          ],
        ),
        FilledButton(
          onPressed: () => flow.next(context),
          child: const Text('Next'),
        ),
      ],
    );
  }
}
