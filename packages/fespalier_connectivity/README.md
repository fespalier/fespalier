# fespalier_connectivity

[fespalier](https://github.com/fespalier/fespalier)'s `reconnectSignal` from `connectivity_plus` (since 0.9.0), so
`Freshness(refetchOnReconnect: true)` loads a route's data again when the device gets a network back, and a `hasNetwork`
provider for an "offline" banner. fespalier itself has no dependency on the plugin: the generated code is the same bytes,
and an app that does not depend on this package pays nothing for it.

**It is connectivity, not reachability.** It says "a network interface is up" and nothing more (connectivity_plus' own docs:
it "only gives you the radio status"). A captive portal, a router with no uplink or a VPN that is down all look connected.
`hasNetwork == false` is reliable ("no network at all"); `true` promises nothing, so a banner should say "No network" and a
failed load should show its own error.

The main README documents all of it:
[Reconnects](https://github.com/fespalier/fespalier#reconnects-fespalier_connectivity) (what fires and what does not, the
banner, connectivity versus reachability, iOS and the web, testing). This page is the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if they are the
same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.8.1
  fespalier_connectivity:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_connectivity
      ref: v0.8.1
```

<!-- x-release-please-end -->

It needs Dart 3.8 and Flutter 3.32 or newer, and takes `connectivity_plus` `>=6.0.0 <8.0.0`.

## Wire it

One line in `startup()`, which stays synchronous: no first-frame cost.

```dart
// lib/app/startup.dart
List<Override> startup() => [reconnectSignal.overrideWith(ConnectivitySignal.new)];
```

A `data.dart` (or a `route.dart` for a folder) with `const freshness = Freshness(staleTime: Duration(seconds: 30),
refetchOnReconnect: true);` then loads again when the device goes **from no network to a network**, if its value is at least
that old. It does not fire on the first answer or on a Wi-Fi to mobile switch, and a reload already under way is not
repeated, so a flapping network needs no debounce timer.

A banner:

```dart
if (!ref.watch(hasNetwork)) const OfflineBanner() // paired with XRoute.watch(ref).isFromCache, "offline copy"
```

## Test it

`FakeConnectivity` (in `package:fespalier_connectivity/testing.dart`) is a `ConnectivitySource`: `set`, `offline()` and
`online()` deliver synchronously, `check()` answers `now`. Override `connectivitySource` with it: **a widget test that reaches
the plugin without it fails** with Flutter's report `while activating platform stream on channel
dev.fluttercommunity.plus/connectivity_status`.

```dart
final fake = FakeConnectivity();
await pumpRouter(tester, AppRoutes.router(),
    overrides: [
      connectivitySource.overrideWithValue(fake),
      reconnectSignal.overrideWith(ConnectivitySignal.new),
    ]);
fake.offline();
fake.online(); // a reconnect: data with refetchOnReconnect loads again if it is stale
```

## Rules

- **No polling, no timer, no debounce.** One subscription to connectivity_plus' event stream while something watches
  `networkConnectivity` (a `refetchOnReconnect` data provider keeps it, a banner too) and none otherwise.
- **iOS drops events while the app is in the background**, and the web sends nothing on listen, so the state is asked again
  on each resume (through fespalier's own `appResumeSignal`) and once at the start.
- **Not reachability.** Whether the server answers is a request to your own server: a compiled recipe in the fespalier-data
  skill's `reconnect-and-network.md`, on connectivity changes and on resume, never on a timer.
