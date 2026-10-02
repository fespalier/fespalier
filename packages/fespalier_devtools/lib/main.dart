// The entry point of fespalier's DevTools extension, and the only file that imports
// `package:devtools_extensions`: it needs `dart:js_interop`, so it does not compile on the VM,
// and nothing that has to be tested sits here. What it does is hand DevTools' `serviceManager`
// to a [VmFespalierClient] and put the UI on top of it.
import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:flutter/material.dart';

import 'src/client.dart';
import 'src/protocol.dart';
import 'src/ui/fespalier_app.dart';

void main() {
  runApp(const DevToolsExtension(child: _Extension()));
}

/// Builds the client below [DevToolsExtension], which is where `serviceManager` exists.
class _Extension extends StatefulWidget {
  const _Extension();

  @override
  State<_Extension> createState() => _ExtensionState();
}

class _ExtensionState extends State<_Extension> {
  final _connected = ValueNotifier<bool>(false);
  late final VmFespalierClient _client;

  @override
  void initState() {
    super.initState();
    final manager = serviceManager;
    void follow() => _connected.value = manager.connectedState.value.connected;
    follow();
    manager.connectedState.addListener(follow);
    _unfollow = () => manager.connectedState.removeListener(follow);
    _client = VmFespalierClient(
      callServiceExtension: manager.callServiceExtensionOnMainIsolate,
      extensionEvents: () => manager.service?.onExtensionEvent,
      connected: _connected,
      hasFespalier: manager.serviceExtensionManager.hasServiceExtension(
        DevToolsMethods.hello,
      ),
      mainIsolate: manager.isolateManager.mainIsolate,
    );
  }

  late final VoidCallback _unfollow;

  @override
  void dispose() {
    _unfollow();
    _client.dispose();
    _connected.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FespalierApp(client: _client);
}
