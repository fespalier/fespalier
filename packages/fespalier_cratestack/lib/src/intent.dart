import 'transport.dart';

/// What an intent is now.
enum IntentStatus {
  /// Written here, not yet decided: never sent, or sent with no answer. Sent again under the same key.
  pending,

  /// Being sent right now (saved before the send, so a crash leaves it "maybe landed": same key next time).
  sent,

  /// Refused by the server; `Intent.reason` is the wire code. Kept until the person discards it.
  failed,

  /// The server answered a conflict (e.g. a stale version); kept until the person resolves or discards it.
  conflict,
}

/// One queued mutation: a decision only the server makes.
///
/// Its call is stored once, encoded, and sent from the store every time, so every attempt is
/// byte-identical, which the server's idempotency layer checks.
final class Intent {
  /// An intent. `IntentQueue.submit` makes these; an app reads them.
  const Intent({
    required this.id,
    required this.seq,
    required this.call,
    required this.createdAt,
    this.subject,
    this.touches = const {},
    this.attempt = 0,
    this.status = IntentStatus.pending,
    this.reason,
    this.failures = 0,
  });

  /// The intent as [toJson] wrote it.
  factory Intent.fromJson(Object? json) {
    final map = json! as Map<String, Object?>;
    return Intent(
      id: map['id']! as String,
      seq: map['seq']! as int,
      call: CrateStackCall.fromJson(map['call']),
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['at']! as int),
      subject: map['subject'] as String?,
      touches: {...(map['touches']! as List<Object?>).cast<String>()},
      attempt: map['attempt']! as int,
      status: IntentStatus.values.byName(map['status']! as String),
      reason: map['reason'] as String?,
      failures: map['failures']! as int,
    );
  }

  /// Random (`Random.secure`), 128 bits, hex.
  final String id;

  /// The order intents were made in on this device.
  final int seq;

  /// What is sent.
  final CrateStackCall call;

  /// When it was made.
  final DateTime createdAt;

  /// What it is about, e.g. `order:42`: it waits behind an undecided earlier intent for the same subject.
  final String? subject;

  /// Revision tags bumped when it is accepted (e.g. `{'orders'}`).
  final Set<String> touches;

  /// Numbers the key: a stored failure moves it to the next one.
  final int attempt;

  /// What it is now.
  final IntentStatus status;

  /// The wire code of a refusal or a conflict, never the server's message.
  final String? reason;

  /// How many times the server answered with a stored failure.
  final int failures;

  /// The `Idempotency-Key` header every attempt of this [attempt] carries: `<id>#<attempt>`.
  String get idempotencyKey => '$id#$attempt';

  /// Whether the server has not decided it yet.
  bool get undecided =>
      status == IntentStatus.pending || status == IntentStatus.sent;

  /// This intent with some fields changed.
  Intent copyWith({
    IntentStatus? status,
    int? attempt,
    int? failures,
    String? reason,
  }) => Intent(
    id: id,
    seq: seq,
    call: call,
    createdAt: createdAt,
    subject: subject,
    touches: touches,
    attempt: attempt ?? this.attempt,
    status: status ?? this.status,
    reason: reason ?? this.reason,
    failures: failures ?? this.failures,
  );

  /// The intent as a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'id': id,
    'seq': seq,
    'call': call.toJson(),
    'at': createdAt.millisecondsSinceEpoch,
    'subject': subject,
    'touches': touches.toList()..sort(),
    'attempt': attempt,
    'status': status.name,
    'reason': reason,
    'failures': failures,
  };

  @override
  String toString() => 'Intent($id, ${status.name})';
}

/// What a submit returns: never a success the server has not given.
sealed class IntentOutcome<T> {
  /// An outcome.
  const IntentOutcome();
}

/// The server accepted it now; [value] is its answer (decoded by the caller's `decode`).
final class Accepted<T> extends IntentOutcome<T> {
  /// An accepted outcome.
  const Accepted(this.value);

  /// The server's answer.
  final T value;
}

/// No answer now; the intent is kept and sent by the next sync under the same key. A page says
/// "will send when back online".
final class Queued<T> extends IntentOutcome<T> {
  /// A queued outcome.
  const Queued(this.intent);

  /// The kept intent.
  final Intent intent;
}

/// What a drain did.
final class DrainReport {
  /// A report.
  const DrainReport({
    this.accepted = 0,
    this.failed = 0,
    this.conflicts = 0,
    this.retained = 0,
    this.offline = false,
    this.reachedServer = false,
  });

  /// Intents the server accepted (deleted).
  final int accepted;

  /// Intents the server refused (kept as `failed`).
  final int failed;

  /// Intents the server answered with a conflict (kept as `conflict`).
  final int conflicts;

  /// Intents still pending after an answer that decided nothing (in flight, `401`, a stored failure).
  final int retained;

  /// Whether the drain stopped at a call that got no answer.
  final bool offline;

  /// Whether any call got an answer from CrateStack, of any kind.
  final bool reachedServer;
}
