// Builds rust/ (the core) for the platform Flutter is building for, and bundles it as a native asset.
// Every `flutter test` runs it for the host; a web build runs it and it does nothing (no code assets on the web).
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await const FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
    ).run(input: input, output: output);
  });
}
