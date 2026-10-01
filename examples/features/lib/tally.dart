import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// A page's state, to see whether it survives a change of the URL: how often the button was
/// pressed. It lives in the widget's `State` (a hook), so it is lost when the page remounts.
class Tally extends HookWidget {
  const Tally({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final taps = useState(0);
    return TextButton(
      onPressed: () => taps.value++,
      child: Text('$label taps ${taps.value}'),
    );
  }
}
