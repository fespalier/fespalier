import 'package:fespalier/fespalier.dart';

/// How many times [data] ran; the tests read it to see that equal keys share a run.
int reportFetches = 0;

/// A section's data.dart can be keyed by query parameters too: `/reports/monthly?period=2026-01`.
/// The layout and every page below it load (or read) the report of the period in the URL,
/// and `ReportsSection.watch(ref, period: '2026-01')` is the typed way to the same provider.
Future<String> data(Ref ref, {String? period}) async {
  reportFetches++;
  return 'Report ${period ?? 'latest'}';
}
