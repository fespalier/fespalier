import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:live/app.g.dart';

/// A question, and the server's answer as it is written: the streaming action of action.dart. The text
/// grows word by word; **Stop** cancels the request and keeps what came.
class AskPage extends HookConsumerWidget {
  const AskPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final question = useTextEditingController(text: 'What is a live answer?');
    final answer = AskRoute.useAnswer(ref);
    final text = answer.value;
    final words = text == null ? 0 : text.split(' ').length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Ask the server', style: Theme.of(context).textTheme.titleMedium),
        TextField(
          controller: question,
          decoration: InputDecoration(
            labelText: 'Question',
            errorText: answer.fieldErrors?.fields['question'],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (answer.isPending)
              FilledButton(onPressed: answer.cancel, child: const Text('Stop'))
            else
              FilledButton(
                onPressed: () => answer.call(question.text),
                child: const Text('Ask'),
              ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(switch (answer.state) {
                StreamIdle() => 'The answer comes word by word',
                StreamRunning() => 'Writing: $words words so far',
                StreamDone() => 'Done: $words words',
                StreamCancelled() => 'Stopped after $words words',
                StreamFailed() when answer.fieldErrors != null => 'Not asked',
                StreamFailed(:final error) => 'The answer stopped: $error',
              }, key: const Key('answer-state')),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (text != null)
          Text(text, key: const Key('answer'))
        else
          const Text(
            'Leave the page while it writes and the request is cancelled: the server log says so.',
          ),
      ],
    );
  }
}
