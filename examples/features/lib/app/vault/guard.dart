import 'package:features/app.g.dart';
import 'package:features/auth.dart';
import 'package:fespalier/fespalier.dart';

/// An asynchronous guard (say, a check with a server). The menu does not wait for it: the
/// entry is listed, and on, while the answer is out, and follows the answer when it
/// arrives. Watch before the first `await`: after it, nothing is tracked.
Future<String?> guard(Ref ref, {required Uri uri}) async {
  final signedIn = ref.watch(session);
  await Future<void>.delayed(const Duration(milliseconds: 10));
  return signedIn ? null : LoginRoute(from: uri.toString()).location;
}
