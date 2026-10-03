import 'package:fespalier/fespalier.dart'
    show MemoryDataStorage, dataCacheStorage;
import 'package:fespalier/startup.dart';

/// Runs before the app (the generated main(), lib/app.main.g.dart, calls it before the router
/// exists) and returns the providers to override.
///
/// products/$id/data.dart has a `dataCache`. This storage keeps its products while the app runs,
/// so a page opened again shows its last product at once. For a cache that survives a restart,
/// give a `Storage<String, String>` on disk instead (riverpod_sqflite's `JsonSqFliteStorage`,
/// say), opened here, before the app runs, so that its `read` is synchronous.
List<Override> startup() => [
      dataCacheStorage.overrideWithValue(MemoryDataStorage()),
    ];
