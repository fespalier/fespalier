import 'dart:math';

final Random _random = Random.secure();

/// [bytes] random bytes from the platform's secure generator, as lower-case hex: an intent's id
/// (16 bytes, 128 bits) and a store's node id (8 bytes). Never derived from the clock or a path.
String randomHex(int bytes) {
  final buffer = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
