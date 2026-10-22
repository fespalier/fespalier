import 'package:fespalier_keypair/fespalier_keypair.dart' show KeyRole;
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart'
    show DeviceSigner;
import 'package:fespalier_transport/fespalier_transport.dart';

/// The header a call puts on itself to ask for the user-present key. Its value is the caption of the
/// prompt. It is a request for the signer, never a header of the wire: [ConfirmTransport] takes it
/// off.
const String confirmHeader = 'x-fespalier-confirm';

/// Turns [confirmHeader] into what `DeviceSigner` reads: the attributes that ask for the
/// user-present key (`roleAttribute`) and say why (`reasonAttribute`).
///
/// A generated call has no attributes to give: its options carry headers, an idempotency key and an
/// abort trigger, and `CratestackHttpRequest.extra` is never filled by the RPC adapter
/// (cratestack/cratestack#1207). A header is
/// what a call can set (`CratestackRpcCallOptions(headers: ...)`), so this decorator, **above the
/// session**, is the translation. It passes every other attribute (the `TransportMemo`) through
/// unchanged, as a decorator must.
final class ConfirmTransport implements HttpTransport {
  /// A transport that reads [confirmHeader] before [inner] signs the request.
  const ConfirmTransport(this.inner);

  /// The session: it signs with the key the attributes ask for.
  final HttpTransport inner;

  @override
  Future<TransportResponse> send(TransportRequest request) {
    String? caption;
    final headers = <String, String>{};
    for (final entry in request.headers.entries) {
      if (entry.key.toLowerCase() == confirmHeader) {
        caption = entry.value;
      } else {
        headers[entry.key] = entry.value;
      }
    }
    if (caption == null) return inner.send(request);
    return inner.send(
      request.copyWith(
        headers: headers,
        attributes: <String, Object?>{
          ...request.attributes,
          DeviceSigner.roleAttribute: KeyRole.userPresent,
          DeviceSigner.reasonAttribute: caption,
        },
      ),
    );
  }
}
