import 'package:features/new_doc.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// A static sibling of the catch-all: `/docs/new` is tried before `/docs/*rest`. What is typed
/// here is held by a [NewDocSource] registered in the page's `LeaveScope`, and `leave.dart` asks
/// before the page goes while it is not empty.
class NewDocPage extends HookWidget {
  const NewDocPage({super.key});

  @override
  Widget build(BuildContext context) {
    final source = useMemoized(NewDocSource.new);
    final controller = useTextEditingController();
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
    return Scaffold(
      body: Column(
        children: [
          const Text('New doc'),
          TextField(
            controller: controller,
            onChanged: source.write,
            decoration: const InputDecoration(labelText: 'Text'),
          ),
          TextButton(
            onPressed: () => source.discard(),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
