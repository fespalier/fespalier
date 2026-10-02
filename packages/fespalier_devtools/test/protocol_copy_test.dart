// The protocol file is shared with the runtime by copy, not by dependency (see AGENTS.md): this is
// what keeps the copy honest.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'lib/src/protocol.dart is the runtime\'s protocol file, byte for byte',
    () {
      final copy = File('lib/src/protocol.dart').readAsStringSync();
      final source = File(
        '../fespalier/lib/src/devtools/protocol.dart',
      ).readAsStringSync();
      expect(
        copy == source,
        isTrue,
        reason:
            'packages/fespalier_devtools/lib/src/protocol.dart differs from '
            'packages/fespalier/lib/src/devtools/protocol.dart: run '
            'scripts/build-devtools-extension.sh (just devtools-build) and commit the result',
      );
    },
  );
}
