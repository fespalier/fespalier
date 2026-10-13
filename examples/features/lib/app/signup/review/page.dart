import 'package:features/app.g.dart';
import 'package:flutter/material.dart';

class SignupReviewPage extends StatelessWidget {
  const SignupReviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final flow = SignupSection.flowOf(context);
    final f = flow.fields;
    return Column(
      children: [
        Text('${f.name.value} <${f.email.value}>'),
        if (flow.error case final error?) Text('Problem: $error'),
        TextButton(
          onPressed: () => flow.goTo(context, SignupStep.name),
          child: const Text('Edit name'),
        ),
        FilledButton(
          onPressed: flow.isPending ? null : flow.submit,
          child: const Text('Create account'),
        ),
        if (flow.state.value case final id?) Text('Created $id'),
      ],
    );
  }
}
