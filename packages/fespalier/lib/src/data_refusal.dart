/// An error the server decided, which a page never shows kept data instead of (since 0.13.1).
///
/// A route whose `data.dart` has a `freshness` or a `dataCache` keeps its page on the value it
/// had when a reload fails (`DataView.keepDataOnError`): right for a lost connection or a 5xx,
/// wrong for an answer. A refusal (a `403`, a `404`, a failed authorization) means the person may
/// no longer see what is on screen, so a failure that implements this goes to `error.dart`
/// instead of the page, even when there is a value. `error.dart` gets no copy of the old value.
///
/// Implement it on the error a data function throws; core knows no client, so
/// `fespalier_cratestack` marks `CrateStackRefused` (every `4xx` but `401` and `409`) and
/// `fespalier_auth` marks `AuthRejected`, which is a refusal only when it reaches the read
/// itself: Dio wraps it in a `DioException`, and after a failed refresh on a `401` the read sees
/// `CrateStackUnauthenticated`, which keeps the page. A plain error stays kept. Checking it never
/// makes a `Future`.
abstract interface class DataRefusal {}
