import 'package:device/api.dart';
import 'package:device/app.g.dart';
import 'package:flutter/material.dart';

class AccountPage extends StatelessWidget {
  const AccountPage({super.key, required this.account});

  /// data.dart's, by type.
  final Account account;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Account')),
    body: ListView(
      children: [
        ListTile(title: Text('Phone: ${account.phone}')),
        ListTile(title: Text('Device: ${account.deviceId}')),
        ListTile(title: Text('Signed with the ${account.signedWith} key')),
        ListTile(
          title: const Text('Send money'),
          onTap: () => const TransferRoute().go(context),
        ),
      ],
    ),
  );
}
