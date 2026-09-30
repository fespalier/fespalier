/// `dart run fespalier <command>`: runs the `fsp` generator that matches this
/// package's version, downloading it from the GitHub release the first time.
/// See `lib/src/launcher.dart`.
library;

import 'dart:io';

import 'package:fespalier/src/launcher.dart';

Future<void> main(List<String> args) async {
  try {
    final launcher = await Launcher.forThisMachine();
    exit(await launcher.run(args));
  } on LauncherException catch (e) {
    stderr.writeln('fespalier: $e');
    exit(1);
  }
}
