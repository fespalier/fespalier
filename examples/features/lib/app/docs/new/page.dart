import 'package:features/app.g.dart';
import 'package:features/new_doc.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// A static sibling of the catch-all: `/docs/new` is tried before `/docs/*rest`. What is typed
/// here is held by a [NewDocSource] registered in the page's `LeaveScope`, and `leave.dart` asks
/// before the page goes while it is not empty.
///
/// `Draft` runs the streaming action of `action.dart` (since 0.25.0) on what is typed: the text
/// grows below the field as it comes, `Stop` cancels it, and `Use draft` puts it in the field.
class NewDocPage extends HookConsumerWidget {
  const NewDocPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = useMemoized(NewDocSource.new);
    final controller = useTextEditingController();
    final draft = NewDocRoute.useDraft(ref);
    useEffect(() {
      final unregister = LeaveScope.maybeOf(context)?.register(source);
      return () {
        unregister?.call();
        source.dispose();
      };
    }, [source]);
    // `discard()` empties the source, and the field follows it.
    useListenable(source);
    if (controller.text != source.text) controller.text = source.text;
    final drafted = draft.value;
    return Scaffold(
      body: Column(
        children: [
          const Text('New doc'),
          TextField(
            controller: controller,
            onChanged: source.write,
            decoration: InputDecoration(
              labelText: 'Text',
              errorText: draft.fieldErrors?.fields['topic'],
            ),
          ),
          TextButton(
            onPressed: () => source.discard(),
            child: const Text('Save'),
          ),
          if (draft.isPending)
            TextButton(onPressed: draft.cancel, child: const Text('Stop'))
          else
            TextButton(
              onPressed: () => draft.call(source.text),
              child: const Text('Draft'),
            ),
          if (drafted != null) ...[
            Text(drafted),
            if (!draft.isPending)
              TextButton(
                onPressed: () {
                  source.write(drafted);
                  draft.reset();
                },
                child: const Text('Use draft'),
              ),
          ],
        ],
      ),
    );
  }
}
