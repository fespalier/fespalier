import 'package:device/api.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// Who the API says this device is. `authTransport` signs the request with the device's key (the
/// ambient one, which never prompts): `X-Attestation` and `X-Signature`, and no `Authorization`.
/// An attestation near its end is renewed first, once, by a silent proof of possession.
Future<Account> data(Ref ref) async {
  // Another user loads this again; a renewal does not.
  ref.watch(authUserId);
  final json = await callApi(ref.watch(authTransport), 'GET', '/me');
  return Account.fromJson(json! as Map<String, Object?>);
}
