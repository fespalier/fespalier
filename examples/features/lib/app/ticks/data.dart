import 'package:fespalier/fespalier.dart';

/// A Stream becomes a StreamProvider.
Stream<int> data(Ref ref) => Stream.value(42);
