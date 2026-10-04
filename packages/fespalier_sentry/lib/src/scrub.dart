import 'package:sentry_flutter/sentry_flutter.dart';

import 'keys.dart';

/// The keys `sentry_dio` and `SentryHttpClient` put the query and the fragment of a request in, on
/// breadcrumbs and on spans.
const List<String> _queryKeys = ['http.query', 'http.fragment'];

/// [url] without its query and its fragment.
String withoutQuery(String url) {
  final cut = url.indexOf(RegExp('[?#]'));
  return cut < 0 ? url : url.substring(0, cut);
}

/// Removes what [data] holds of a request's query: `http.query`, `http.fragment`, and the query of
/// `url`. Returns whether anything changed.
bool _scrub(Map<String, dynamic> data) {
  var changed = false;
  for (final key in _queryKeys) {
    changed |= data.remove(key) != null;
  }
  final url = data['url'];
  if (url is String) {
    final clean = withoutQuery(url);
    if (clean != url) {
      data['url'] = clean;
      changed = true;
    }
  }
  return changed;
}

/// Whether [breadcrumb] is one `SentryNavigatorObserver` made (`didPush`, `didPop`, `didReplace`):
/// the sink's own page breadcrumbs say the same with the route pattern, so `configure` drops
/// these.
bool isObserverBreadcrumb(Breadcrumb breadcrumb) =>
    breadcrumb.category == SentryKeys.navigationCategory &&
    (breadcrumb.data?.containsKey('state') ?? false);

/// [breadcrumb] without the query and fragment values of an HTTP request.
Breadcrumb? breadcrumbWithoutQueries(Breadcrumb? breadcrumb, Hint hint) {
  final data = breadcrumb?.data;
  if (breadcrumb == null || data == null) return breadcrumb;
  final copy = Map<String, dynamic>.of(data);
  if (!_scrub(copy)) return breadcrumb;
  return Breadcrumb(
    message: breadcrumb.message,
    timestamp: breadcrumb.timestamp,
    data: copy,
    level: breadcrumb.level,
    category: breadcrumb.category,
    type: breadcrumb.type,
  );
}

/// [event] without the query and fragment of its request.
SentryEvent? eventWithoutQueries(SentryEvent event, Hint hint) {
  final request = event.request;
  if (request != null) {
    request
      ..queryString = null
      ..fragment = null;
    final url = request.url;
    if (url != null) request.url = withoutQuery(url);
  }
  return event;
}

/// Whether [transaction] is a navigation that a newer one superseded: it never showed a screen.
bool isSuperseded(SentryTransaction transaction) =>
    transaction.tags?[SentryKeys.navigationOutcome] == 'superseded';

/// [transaction] without query and fragment values on the data of its spans, or null for a
/// navigation that a newer one superseded: it never showed a screen.
SentryTransaction? transactionWithoutQueries(
  SentryTransaction transaction,
  Hint hint,
) {
  if (isSuperseded(transaction)) return null;
  eventWithoutQueries(transaction, hint);
  for (final span in transaction.spans) {
    // A finished span's data is the SDK's own map: what the HTTP integrations wrote.
    _scrub(span.data);
  }
  return transaction;
}
