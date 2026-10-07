# Links: `RouteLink`

As of v0.5.0. `RouteLink` is the widget for a link **between pages**: a typed
route (or a location string) with a child you draw. On the web it is a real
`<a href>`; everywhere, a plain click goes through go_router. Reach for it
instead of `onTap: () => XRoute(...).go(context)` when a link should show its
URL, open in a new tab, or preload the page behind it.

The samples use this small app.

```dart
// lib/products.dart
class Product {
  const Product(this.id, this.name);

  final int id;
  final String name;
}

Future<Product> fetchProduct(int id) async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return Product(id, 'Product $id');
}
```

```dart
// lib/app/products/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/products.dart';

Future<Product> data(Ref ref, {required int id}) => fetchProduct(id);
```

```dart
// lib/app/products/$id/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/products.dart';

class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) => Text(product.name);
}
```

```dart
// lib/app/products/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class ProductsPage extends StatelessWidget {
  const ProductsPage({super.key});

  @override
  Widget build(BuildContext context) => Material(
    child: Column(
      children: [
        for (var id = 1; id <= 3; id++)
          RouteLink(
            to: ProductRoute(id: id),
            preload: Preload.intent,
            builder: (context, follow) =>
                ListTile(title: Text('Product $id'), onTap: follow),
          ),
      ],
    ),
  );
}
```

```dart
// test/links_test.dart
import 'package:fespalier/testing.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';

void main() {
  testWidgets('hovering preloads, a click navigates', (tester) async {
    final container = await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/products'),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    expect(container.exists(ProductRoute.data(2)), isFalse);
    await mouse.moveTo(tester.getCenter(find.text('Product 2')));
    await tester.pump();
    expect(container.exists(ProductRoute.data(2)), isTrue);

    await tester.tap(find.text('Product 2'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/products/2');
  });
}
```

## The parts

```dart
RouteLink(
  to: ProductRoute(id: 2),          // a typed route, or uri: Uri.parse('/products/2')
  locale: 'fr',                     // optional: the localized spelling (locationFor)
  method: LinkMethod.go,            // go (default) | push | replace
  preload: Preload.visible,         // none | intent | visible; null: the RouteLinkScope's
  onPreload: (context) => ...,      // since 0.9.0: runs when the link starts a preload
  builder: (context, follow) => ...,
)
```

- **`onPreload`** (since 0.9.0) is `void Function(BuildContext context)`: it runs with the link's context right
  after the link starts `route.preload(ref)`, for what the page needs that is not a provider (its image at the
  size it shows it: `ResponsiveImage.precache(context, p.image, width: pagePhotoSize, aspectRatio: 1)` from
  `package:fespalier_image`). For `Preload.intent` it runs on the first intent and on the next one after a failed
  preload; for `Preload.visible` each time the link comes back on screen. It is **not** called when the link
  preloads nothing (`Preload.none`, or a `uri:` link no `RouteLinkScope.match` matches). It must return at once;
  what it throws is reported with `FlutterError.reportError` (library `fespalier`, context `while running
onPreload of a RouteLink to /products/3`) and the preload goes on.

- **Exactly one of `to` and `uri`** (an assertion). `to` is a `TypedLocation`;
  `uri` is a path of **this app with the mount prefix and query**
  (`Uri.parse('/shop/products/2?tab=a')`), not an external URL: for another
  site use `url_launcher`'s `Link`. Prefer `to`: a renamed folder breaks the
  build, not a link.
- **`builder` gets `follow`**; give it to `onTap`/`onPressed`. A link that is
  never given `follow` shows an `href` and does nothing on click. `follow` takes
  no arguments and returns nothing.
- **No `extra`.** An `extra` is not in the URL, so a link cannot carry one; for
  a route that takes one, call `route.go(context, extra: ...)` from your own
  `onTap`.
- It needs the app's **`ProviderScope`** above it, like every fespalier page, even
  when it preloads nothing.
- The widget is `const`-constructible, and the child is exposed to accessibility
  services as a **link with its URL**.
- `package:fespalier/fespalier.dart` exports `RouteLink`, `RouteLinkScope`,
  `Preload` and `LinkMethod`.

## The web: an anchor and a router click

On the web `RouteLink` wraps `url_launcher`'s `Link`, which lays an invisible
`<a href>` over the child. The two meet like this:

- The **`href` is the location** `to.locationFor(locale)` writes (or the `uri`),
  so it carries the **mount prefix** (`/shop/products/2` under
  `AppRoutes.mount(at: '/shop')`) and the localized spelling; the browser
  prefixes it for the URL strategy (`#/...` under hash routing). The status bar
  shows it, and the context menu offers "open in a new tab".
- A **plain click or a keyboard activation** runs `follow`, which calls
  `GoRouter.go`, `push` or `replace`. The page does not reload, and the anchor's
  own navigation is cancelled (url_launcher cancels it when `follow` did not
  hand the click to the anchor). So `method: LinkMethod.push` really pushes.
- A **middle click**, or a click with **Ctrl, Cmd, Shift or Alt** held, is the
  browser's: it opens a new tab or window on the `href`. A new tab is a cold
  start of the app at that URL, so `guard.dart` runs there.
- Off the web there is no anchor; the same `follow` navigates.

## `uri:` links in debug

Since 0.7.0 the same check also happens **statically**: `fsp gen`, `check` and `watch` warn at a
`Uri.parse('...')` literal in `RouteLink(uri: ...)` that matches no route
(``no route matches `/nope`, so it shows not-found [unknown_path]``), before the app runs.
It does not see a `uri:` that is built or held in a variable, and does not check segment
types; see `typed-routes-and-extra.md`, "String paths".

In a debug build a `uri:` that matches no route throws a `FlutterError` when the
link builds (`RouteLink(uri: /nope) points at no route of this app.`), and so
does a `uri:` with a scheme or host (`is not a location in this app`). It asks
the router above it by default, which cannot see a **segment that does not
parse** (`/products/abc` where the id is an `int`). To check those too, give the
app a scope with the generated matcher:

```dart
MaterialApp.router(
  routerConfig: router,
  builder: (context, child) => RouteLinkScope(
    preload: Preload.intent,         // for every link that does not say
    match: AppRoutes.matchUrl,       // checks `uri:` exactly, and lets it preload
    child: child!,
  ),
)
```

Release builds skip the check. Without `match`, a `uri:` link preloads nothing:
only a typed route (or the generated matcher) knows which providers a location
reads.

## Preloading

`preload:` starts the data of the page the link points at, through
`route.preload(ref)` (see
[`fespalier-data`](../../fespalier-data/references/prefetch-and-lookup.md)),
and the link owns the handle. Since 0.7.0 that call also starts the page's **code**
when the route is [deferred](route-dart.md#deferred-load-a-pages-code-on-demand)
(`const deferred = true;`): the chunk is fetched with the data, and once loaded it
stays loaded, so releasing the handle drops the data only. Before 0.7.0 a link
preloaded data only. A `uri:` link goes through the matched route's `preload` too,
so a hand-built `UrlMatch` whose route does not override `preload` preloads nothing:

- `Preload.none`, the default.
- `Preload.intent`: the pointer enters the link, something in it takes focus, or
  a pointer goes down on it. Held until the link is disposed.
- `Preload.visible`: while the link is inside the view and the viewport of every
  scrollable around it, on a route or tab that is showing; released when it
  scrolls out or another page covers it.

It never navigates, runs no guard, keeps no failure, and starts a provider once
however often the pointer comes and goes. The handle is closed when the link is
disposed, or when its route or `preload` changes. A link whose load failed tries
again on its next intent, never on every scroll tick of a visible one.

## Testing a link

- A hover needs a **mouse** pointer: `tester.createGesture(kind:
PointerDeviceKind.mouse)`, `addPointer`, then `moveTo` the link; `addTearDown(
gesture.removePointer)`. To enter again, move off it and `pump` first.
- A touch **going down** preloads: `tester.startGesture(...)` before `up()`.
- Check what was started with `container.exists(XRoute.data(...))`; an
  `autoDispose` provider is gone one `pump` after its handle closes.
- No timer is involved, so nothing needs waiting for; `pumpAndSettle` after the
  tap that navigates, as for any `go`.
- The `href` is `tester.widget<Link>(find.byType(Link)).uri`
  (`package:url_launcher/link.dart`); semantics are `tester.getSemantics(...)`
  with `ensureSemantics()`.

## Platform links end to end (since 0.12.0)

Not `RouteLink`: a link the **platform** opens. `docs/navigation.md` has the page, "Platform links end to end" and
"With a deep-link plugin (app_links, Branch)"; `docs/cli.md` has `fsp links`.

1. `links:` (`domains`, `scheme`, `android_package` + `android_sha256`, `ios_app_id`, and `android_manifest:` /
   `ios_entitlements:` to let `fsp links` edit the platform files), then `fsp links`, and `fsp links --check` in CI.
   `out: false` (since 0.12.0) writes no sitemap and no `.well-known` files: `fsp links` and `--check` then handle only the
   platform files, and `android_sha256` is optional (it only feeds `assetlinks.json`); an old `links/` folder is left alone.
   `out: true` is an error.
2. Serve `web/.well-known/assetlinks.json` and `apple-app-site-association` at `https://<domain>/.well-known/`, as JSON,
   with no redirect.
3. On a device: `adb shell am start -a android.intent.action.VIEW -d "https://shop.example.com/orders/42" com.example.shop`
   (`adb shell pm get-app-links <package>` lists each domain's verification), `xcrun simctl openurl booted <url>`.
4. In a widget test, `await sendPlatformLink(tester, Uri.parse('https://shop.example.com/orders/42'))` after `pumpRouter`
   (`package:fespalier/testing.dart`): a warm link through `flutter/navigation`, pumped until idle. Cold start:
   `tester.binding.platformDispatcher.defaultRouteNameTestValue` before `pumpRouter`. `source=link` and `onEnter` need a
   router made with `links: true` (an app with telemetry or adapters); the page opens either way. It cannot prove a
   domain is verified.

`fsp links` warns, and does not fail `--check`, when Flutter's switch is off: `flutter_deeplinking_enabled is false in
{manifest}: Flutter will not hand links to the router` (`<meta-data android:name="flutter_deeplinking_enabled"
android:value="false" />`), and `FlutterDeepLinkingEnabled is false in ios/Runner/Info.plist` (`<false/>`, or any value other than true: `"0"`, `<string>NO</string>`, `<integer>0</integer>`; the manifest tag counts
under an `<activity>`). Both files are only read. Right when a plugin owns the links; otherwise delete the key.

**With a deep-link plugin** (`app_links`, Branch): the plugin needs the switch off, so go_router gets no link and nothing is
marked `link`. Write an adapter in a small path package (the app cannot list itself in `adapters:`): `launch()` returns
`InboundLaunch(location, source: NavigationSource.link)` from the plugin's initial link, a local read (remember the URI);
`attach(router, container)` does `container.listen` on a `StreamProvider<Uri>` over the plugin's stream and calls
`navigateFrom(NavigationSource.link, () => router.go(location))`, **skipping the first event equal to the URI `launch()`
used** (`app_links`' stream also delivers the initial link, so it would open twice). A deferred deep link is a `launch()`
only when already cached on the device (`launch()` must not wait on the network); one resolved over the network is
forwarded from `attach` like a warm link. A second router over the same container adds a second listener.
`locationOf(uri)` is yours and answers null for a link that is not the app's.

## Not built

- No external links (use `Link`), no `target` (a new tab is the browser's
  modifier click), and no `extra`. (Code is preloaded since 0.7.0, for a deferred route;
  on 0.6.0 and earlier a link preloaded data only.)
- No generated app-wide default: `RouteLinkScope` is the runtime one.
