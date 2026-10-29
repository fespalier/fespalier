import 'package:fespalier/fespalier.dart';
import 'package:live/inbox.dart';
import 'package:live/requests.dart';
import 'package:live/wiring.dart';

/// The threads of the inbox, read once: what changes is in each thread, which the change feed reloads.
Future<List<ThreadSummary>> data(Ref ref) async {
  final json = await getJson(
    ref.watch(liveTransport),
    ref.watch(liveOrigin).resolve('inbox'),
  );
  return [
    for (final thread in json! as List<Object?>)
      if (thread case {'id': final String id, 'title': final String title})
        ThreadSummary(id, title),
  ];
}
