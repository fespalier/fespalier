import 'dart:typed_data';

import 'cbor.dart';

/// The COSE_Sign1 tag.
const int sign1Tag = 18;

/// The bytes a signature covers (RFC 9052 §4.4):
/// `["Signature1", protected, external_aad, payload]`, the protected header exactly as it is on
/// the wire (never re-encoded) and the AAD as a byte string.
Uint8List sigStructure({
  required List<int> protected,
  required List<int> externalAad,
  required List<int> payload,
}) {
  return (CborWriter()
        ..head(majorArray, 4)
        ..tstr('Signature1')
        ..bstr(protected)
        ..bstr(externalAad)
        ..bstr(payload))
      .toBytes();
}

/// The sealed message: `Tag(18) [protected bstr, {} , payload bstr, signature bstr]`.
Uint8List sign1Message({
  required List<int> protected,
  required List<int> payload,
  required List<int> signature,
}) {
  return (CborWriter()
        ..head(majorTag, sign1Tag)
        ..head(majorArray, 4)
        ..bstr(protected)
        ..raw(cborEmptyMap)
        ..bstr(payload)
        ..bstr(signature))
      .toBytes();
}
