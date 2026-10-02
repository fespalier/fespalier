// A library the tests import `deferred as`: its code is only reachable after loadLibrary.
import 'package:flutter/widgets.dart';

/// The page of a real deferred import.
class DeferredPage extends StatelessWidget {
  const DeferredPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('deferred page');
}
