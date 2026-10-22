import 'dart:math';

final Random _random = Random.secure();

/// A fresh `Idempotency-Key`: 128 random bits as hex.
///
/// A key belongs to **one logical write**, minted by the action that starts it and sent with the
/// call (`CratestackRpcCallOptions(idempotencyKey: ...)`). The session sends a request again after
/// it renewed the attestation (a `401 attestation_expired`), with a new signature over the very same
/// bytes and headers: the same key, so the server answers the replay from what it stored and the
/// write runs once.
String newIdempotencyKey() => [
  for (var i = 0; i < 16; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();
