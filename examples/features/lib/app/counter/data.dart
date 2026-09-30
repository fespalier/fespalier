import 'package:fespalier/fespalier.dart';

/// data.dart can export any async provider; this one is a notifier the page
/// talks to through `CounterRoute.data`.
final data = AsyncNotifierProvider.autoDispose<Counter, int>(Counter.new);

class Counter extends AsyncNotifier<int> {
  @override
  Future<int> build() async => 0;

  void increment() => state = AsyncData((state.value ?? 0) + 1);
}
