/// Whether the HTTP status [httpStatus] of a failed upload proves that the server did not apply
/// the write (since 0.16.0).
///
/// Only a client error does, and not every one: `408` (the server gave up waiting for the rest of a
/// request it was already handling) and `499` (the client's connection closed while the server went
/// on) say nothing about what the server did. Every `5xx` is the same kind of answer: a gateway's
/// `502` or `504`, or the server's own `500` after the commit, tells nothing about whether the
/// write ran. Such an answer is an unknown outcome, like a lost response, and `Uploads` never sends
/// a write without an `Idempotency-Key` again after it.
bool provesNothingApplied(int httpStatus) =>
    httpStatus >= 400 &&
    httpStatus < 500 &&
    httpStatus != 408 &&
    httpStatus != 499;
