import 'package:fespalier/fespalier.dart'
    show MemoryDataStorage, dataCacheStorage;
import 'package:fespalier/startup.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_image/fespalier_image.dart' show imageCdnProvider;
import 'package:http/http.dart' as http;
import 'package:shop/images.dart';

/// Runs before the app (the generated main(), lib/app.main.g.dart, calls it before the router
/// exists) and returns the providers to override.
///
/// products/$id/data.dart has a `dataCache`. This storage keeps its products while the app runs,
/// so a page opened again shows its last product at once. For a cache that survives a restart,
/// give a `Storage<String, String>` on disk instead (riverpod_sqflite's `JsonSqFliteStorage`,
/// say), opened here, before the app runs, so that its `read` is synchronous.
///
/// The product photos come from the image CDN `shopImages` names (lib/images.dart), fetched through
/// the app's one transport, built here: `HttpClientTransport` over `package:http`. A shop with a
/// session or tracing wraps it once (`SessionTransport`, `OtelTransport`) and every package that
/// sends gets the wrapped one.
List<Override> startup() {
  final transport = HttpClientTransport(http.Client());
  return [
    dataCacheStorage.overrideWithValue(MemoryDataStorage()),
    imageCdnProvider.overrideWithValue(shopImages(transport)),
  ];
}
