import 'package:device/api.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';

/// Who gets the money, and how much.
typedef TransferInput = ({String to, int cents});

/// A write worth a prompt: the request asks for the **user-present** key through its attributes,
/// so the signature is made behind a biometric or the device credential (`reasonAttribute` is its
/// caption). Ordinary requests never ask for it.
///
/// A cancelled prompt is a [UserPresenceRefused]: it fails this one request, and the session, the
/// ambient key and every other request go on working. The page shows it and lets the user try again.
Future<String> send(Ref ref, {required TransferInput input}) async {
  final json = await callApi(
    ref.read(authTransport),
    'POST',
    '/transfers',
    json: {'to': input.to, 'cents': input.cents},
    attributes: const {
      DeviceSigner.roleAttribute: KeyRole.userPresent,
      DeviceSigner.reasonAttribute: 'Confirm the transfer',
    },
  );
  return 'Transfer ${(json! as Map<String, Object?>)['id']} sent to ${input.to}';
}
