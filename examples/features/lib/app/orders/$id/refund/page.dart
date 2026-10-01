import 'package:features/app.g.dart';
import 'package:features/refunds.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// Quotes a refund (`data.dart` beside this file) and asks for one (`action.dart`). `confirm/`
/// is not below this page in the stack, although its URL is: see `confirm/route.dart`.
///
/// The form is a [HookConsumerWidget]: `RefundRoute.useAction` gives its pending and error
/// state, so the page holds no `isSubmitting` and no `try`/`catch` of its own.
class RefundPage extends HookConsumerWidget {
  const RefundPage({super.key, required this.id, required this.quote});

  final int id;
  final String quote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final amount = useTextEditingController();
    final submit = RefundRoute.useAction(ref, id: id);
    final refunded = submit.state.value;
    return Scaffold(
      appBar: AppBar(title: Text('Refund order $id')),
      body: Column(
        children: [
          Text(quote),
          TextField(
            controller: amount,
            decoration: const InputDecoration(labelText: 'Amount'),
          ),
          TextButton(
            // One refund at a time: a second tap while one is pending does nothing.
            onPressed: submit.isPending
                ? null
                : () => submit.call(
                      RefundInput(amount: int.tryParse(amount.text) ?? 0),
                    ),
            child: const Text('Refund'),
          ),
          if (submit.isPending) const Text('Refunding...'),
          if (submit.hasError) Text('${submit.state.error}'),
          if (refunded != null) Text('Refunded ${refunded.amount} EUR'),
          TextButton(
            onPressed: () => ConfirmRefundRoute(id: id).go(context),
            child: const Text('Continue'),
          ),
          TextButton(
            onPressed: () => ReceiptRoute(id: id).go(context),
            child: const Text('Receipt'),
          ),
        ],
      ),
    );
  }
}
