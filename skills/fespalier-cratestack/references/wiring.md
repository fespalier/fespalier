# Wiring it once

Since 0.10.0. Everything the app writes is in four places: **`startup.dart`** (the overrides), **the Dio**, **the root
`layout.dart`** (`autoSync`) and **the sign-out**. The generated package is yours, so the sample builds against a few
**stand-ins** for it (marked as such); the real ones are `CratestackDioAdapter`, `CratestackRpcException` and the
generated client.

## The stand-ins for your generated package

```dart
// lib/shop_adapter.dart
import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart';

/// STAND-INS for the generated package (shop_client): CratestackDioAdapter, CratestackRpcException and the
/// provider the riverpod preset writes. Yours have the same shapes with more members.
class ShopAdapter {
  const ShopAdapter({required this.dio});

  final Dio dio;

  Future<Object?> call(String opId, Object? input, {String? idempotencyKey}) async => null;
}

class ShopException implements Exception {
  const ShopException(this.status, this.code, this.message, [this.details]);

  final int status;
  final String code;
  final String message;
  final Object? details;
}

final shopAdapterProvider = Provider<ShopAdapter>((ref) => throw UnimplementedError('override it in startup()'));
```

```dart
// lib/shop_transport.dart
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:my_app/shop_adapter.dart';

/// Over the generated adapter: the app's own, because the adapter's types live in the app's generated package.
final class ShopTransport implements CrateStackTransport {
  const ShopTransport(this.adapter);

  final ShopAdapter adapter;

  @override
  Future<Object?> send(CrateStackCall call, {String? idempotencyKey}) => switch (call) {
    RpcCall(:final opId, :final input) => adapter.call(opId, input, idempotencyKey: idempotencyKey),
    RestCall() => throw UnsupportedError('this app uses the RPC transport'),
  };
}

/// The error reader: the generated exception becomes a classification. `fromEnvelope` applies the status and code table.
CrateStackFailure? readShopError(Object e) => e is ShopException
    ? CrateStackFailure.fromEnvelope(status: e.status, code: e.code, message: e.message, details: e.details)
    : null;
```

## The Dio

```dart
// lib/dio.dart
import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/dio.dart';
import 'package:fespalier_dio/fespalier_dio.dart';

final dio = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
    ..interceptors.addAll(const [CrateStackCancelInterceptor(), CrateStackPortalInterceptor()]);
  WriteGuard.install(dio); // last: it goes first
  ref.onDispose(dio.close);
  return dio;
});
```

`WriteGuard.install` puts the guard **first** in the chain, and calling it again moves it back there, so call it after
adding the others (a session interceptor from `fespalier_auth`, `SessionInterceptor`, goes in with them). A second send
of a write is refused except after a `401`; `fespalier_dio`'s `WriteNotRetried` is what such a send fails with when
the guard was not first.

## `startup.dart`

```dart
// lib/foreground_ticker.dart
import 'dart:async';

import 'package:fespalier/fespalier.dart';

/// The app-owned periodic trigger: autoDispose, watched only by autoSync, so the timer lives while the root layout shows.
class ForegroundTicker extends RefetchSignal {
  @override
  int build() {
    final timer = Timer.periodic(const Duration(minutes: 5), (_) => fire());
    ref.onDispose(timer.cancel);
    return 0;
  }
}
```

```dart
// lib/app/startup.dart
import 'package:fespalier/fespalier.dart' show dataCacheStorage, reconnectSignal;
import 'package:fespalier/startup.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_connectivity/fespalier_connectivity.dart';
import 'package:fespalier_cratestack/dio.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/hive.dart';
import 'package:fespalier_storage/fespalier_storage.dart';
import 'package:my_app/dio.dart';
import 'package:my_app/foreground_ticker.dart';
import 'package:my_app/shop_adapter.dart';
import 'package:my_app/shop_transport.dart';
import 'package:path_provider/path_provider.dart';

Future<List<Override>> startup() async {
  // A folder the system does not empty: the application support directory, never a cache directory.
  final dir = await getApplicationSupportDirectory();
  final store = await HiveLocalStore.open(directory: dir.path);
  final prefs = await PrefsDataStorage.open(); // null when shared preferences could not open: nothing is saved
  return [
    // the generated client's adapter, on a Dio you configure
    shopAdapterProvider.overrideWith((ref) => ShopAdapter(dio: ref.watch(dio))),

    // the two seams
    crateStackTransport.overrideWith((ref) => ShopTransport(ref.watch(shopAdapterProvider))),
    crateStackErrors.overrideWithValue(const CrateStackErrors([readShopError, DioFailures.read])),

    // whose data it is, and where queued work lives
    crateStackScope.overrideWith((ref) => ref.watch(authUserId)),
    localStore.overrideWithValue(store),

    // optional: reads in the storage your dataCache already uses, with their key list in the durable store
    if (prefs != null) dataCacheStorage.overrideWithValue(prefs),
    if (prefs != null) readCache.overrideWithValue(ReadCache.storage(prefs, index: store)),

    // the triggers
    reconnectSignal.overrideWith(ConnectivitySignal.new), // fespalier_connectivity
    syncTicker.overrideWith(ForegroundTicker.new),
  ];
}
```

```yaml
# pubspec.yaml dependencies
  dio: ^5.7.0
  path_provider: ^2.1.0
```

- **The order of the readers is the rule**: the app's reader for its generated exception first, then
  `DioFailures.read` for what Dio throws. An error neither knows is `null`, and is rethrown by a read and kept as
  `Queued` by a `submit`.
- **`localStore` has a default that loses everything at exit** (`InMemoryLocalStore`). Override it with
  `HiveLocalStore` on a device. `HiveLocalStore.open` throws
  `ArgumentError: fespalier_cratestack: HiveLocalStore.open needs a directory off the web (a folder the system does not empty, e.g. the application support directory)`
  with no directory; on the web the directory is ignored and the box lives in IndexedDB.
- **On the web**, Flutter's main isolate cannot use CrateStack's embedded wasm store (OPFS needs a dedicated worker):
  use `InMemoryLocalStore` (nothing outlives the tab) or `HiveLocalStore` on IndexedDB. Both are synchronous after
  opening.
- `crateStackScope` is a plain `Provider<String?>`: `null` while nobody is signed in, and everything the package
  stores is keyed by it. Without an override it is `null`, and `submit` throws `StateError`.

## The root layout and the sign-out

```dart
// lib/app/layout.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter/material.dart';

class RootLayout extends ConsumerWidget {
  const RootLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(autoSync); // once: start, resume, reconnect and the tick; its state can drive a banner
    return child;
  }
}
```

```dart
// lib/sign_out.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// The wipe first: fespalier_auth's signOut() sets SignedOut before its first await, so crateStackScope is null
/// as soon as it is called, and a late clear() would find no account. A late one can name it: clear(scope: id).
Future<void> signOutAndWipe(WidgetRef ref) async {
  await ref.read(crateStackAccount).clear();
  await ref.read(authSession.notifier).signOut();
}
```

`clear` deletes the account's intents, owned rows, sync cursors and cached reads. A `401` on a queued call keeps the
intent and its key (the session is being renewed); only a sign-out removes the account's queue.

## Where the code is

`packages/fespalier_cratestack/lib/src/transport.dart`, `errors.dart`, `scope.dart`, `hive_store.dart`, `auto_sync.dart`
and `dio/`; `README.md` of the package has the install block.
