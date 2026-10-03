import 'package:fespalier/fespalier.dart';

/// What the observe.dart hooks write down: a stand-in for an analytics client. A real app would
/// call its SDK here; the tests read this list.
class Views extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  /// Writes [view] down.
  void add(String view) => state = [...state, view];
}

/// The views the hooks saw, in order: `enter /orders/:id`, `leave /orders/:id`.
final NotifierProvider<Views, List<String>> views =
    NotifierProvider<Views, List<String>>(Views.new);
