import 'package:flutter/material.dart';
import 'package:frb_cose_example/src/core.dart';
import 'package:frb_cose_example/src/core_view.dart';
import 'package:frb_cose_example/src/device_key.dart';

/// The Rust core: this device's key and whether it is hardware-backed, whether the server registered it, and the calls
/// the core accepted, newest last.
///
/// A row says what happened and holds nothing sent or received: no arguments, no body and no server's text.
class CorePage extends StatelessWidget {
  const CorePage({super.key, required this.view});

  /// From data.dart: the core's state, read when it last changed.
  final CoreView view;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('The Rust core')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!view.available)
          const Text(
            'Not built for the web: the Rust core is not in this build, so there is no key, no registration and no '
            'journal.',
          )
        else ...[
          Text('Device key ${view.kid}'),
          Text(_describeKey(view.keyKind)),
          Text(
            view.registered
                ? 'Registered with the server.'
                : 'Not registered yet: the first call registers the key.',
          ),
          const SizedBox(height: 16),
          if (view.journal.isEmpty) const Text('No calls yet.'),
          for (final row in view.journal)
            ListTile(
              title: Text(row.op),
              subtitle: Text(_describe(row)),
              contentPadding: EdgeInsets.zero,
            ),
        ],
      ],
    ),
  );
}

/// Whether the key is hardware-backed, and, when it is not, what that costs. The fallback to a software key is never
/// silent: this line is where a person sees it.
String _describeKey(DeviceKeyKind kind) => switch (kind) {
  DeviceKeyKind.hardware => 'Hardware-backed: a secure element holds the key.',
  DeviceKeyKind.software =>
    'Not hardware-backed: the key is a software key. Linux and Windows have no keystore, '
        "and an iOS simulator's keychain is not a secure element.",
  DeviceKeyKind.inMemory =>
    'Not hardware-backed: the keystore did not open, so this run uses a software key in memory. '
        'It does not survive a restart: the next run is a new device to the server.',
  DeviceKeyKind.none => 'No device key in this build.',
};

String _describe(JournalEntry row) {
  final sent = row.sent ? 'sent' : 'not sent';
  final status = row.status == null ? '' : ', status ${row.status}';
  final key = row.idempotencyKey.isEmpty ? '' : ', key ${row.idempotencyKey}';
  return '${row.outcome.name} ($sent$status$key)';
}
