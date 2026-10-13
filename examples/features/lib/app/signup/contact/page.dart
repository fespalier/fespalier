import 'package:features/app.g.dart';
import 'package:flutter/material.dart';

class SignupContactPage extends StatelessWidget {
  const SignupContactPage({super.key});

  @override
  Widget build(BuildContext context) {
    final flow = SignupSection.flowOf(context);
    final f = flow.fields;
    return Column(
      children: [
        TextField(
          controller: f.email.controller,
          decoration:
              InputDecoration(labelText: 'Email', errorText: f.email.error),
        ),
        TextField(
          controller: f.phone.controller,
          decoration:
              InputDecoration(labelText: 'Phone', errorText: f.phone.error),
        ),
        Row(
          children: [
            TextButton(
              onPressed: () => flow.back(context),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => flow.next(context),
              child: const Text('Next'),
            ),
          ],
        ),
      ],
    );
  }
}
