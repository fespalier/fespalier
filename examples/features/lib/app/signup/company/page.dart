import 'package:features/app.g.dart';
import 'package:flutter/material.dart';

class SignupCompanyPage extends StatelessWidget {
  const SignupCompanyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final flow = SignupSection.flowOf(context);
    final f = flow.fields;
    return Column(
      children: [
        TextField(
          controller: f.company.controller,
          decoration:
              InputDecoration(labelText: 'Company', errorText: f.company.error),
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
