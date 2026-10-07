import 'package:features/app.g.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_forms/fespalier_forms.dart';
import 'package:flutter/material.dart';

/// The layout outlives the change of step, so it owns the form: `useFlow` makes it (a draft is
/// kept by default, with the steps done) and a `FormFlowScope` gives it to the step pages below,
/// which read it with `SignupSection.flowOf(context)`.
class SignupLayout extends HookConsumerWidget {
  const SignupLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = SignupSection.useFlow(ref);
    return FormFlowScope(
      flow: flow,
      child: Column(
        children: [
          LinearProgressIndicator(value: flow.progress),
          Text('Step ${flow.index + 1} of ${flow.count}'),
          Expanded(child: child),
        ],
      ),
    );
  }
}
