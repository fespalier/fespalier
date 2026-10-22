# In-context editing (debug only)

Since 0.10.0. Edit a translation in the running app and see it at once, without waiting for Tolgee's CDN. It is a
development tool: **a release or profile build contains none of it, and a key is never in a build.**

## When it is compiled in

Only when **both** hold: a debug build, and `--dart-define=fespalier_tolgee.in_context=true`
(`kTolgeeInContext` in `package:fespalier_tolgee/in_context.dart`). In release and profile builds `kTolgeeInContext` is
a `const false`, and the scope's only other condition is behind `kDebugMode`, so the panel, the editor and the key's
`String.fromEnvironment` are compiled out.

```sh
flutter run --dart-define-from-file=tolgee.local.json
```

`tolgee.local.json` is **gitignored** and holds:

```json
{ "fespalier_tolgee.in_context": "true", "TOLGEE_API_KEY": "tgpak_..." }
```

(`TOLGEE_API_URL` defaults to `https://app.tolgee.io`; set it for a self-hosted Tolgee.)

- **Give the key only the scope it needs: `translations.edit`.**
- **Never pass the key to `flutter build`**, and never write it in a `--dart-define` of a CI job that builds a release:
  a key in a build is public. Release builds pass only `TOLGEE_CDN_URL`. `TolgeeCdn` has no parameter for a key, and
  `test/no_secrets_test.dart` greps `lib/` for key code, so the only reader of `TOLGEE_API_KEY` is the editor, behind
  `kTolgeeInContext`.
- Without a key the panel is **read only**.

## What it does

A small handle opens a panel with the keys **read on the current screen** (`context.tr` and `TrText` record them), their
value and their origin (`TranslationOrigin`). A save calls `PUT /v2/projects/translations` with `X-API-Key` and puts
the text into the **edited** layer, the first link of the chain, so the screen changes at once. Everyone else sees it
when Tolgee publishes (up to 15 minutes). A failed save throws a
`TransportStatusError` (its text is `TransportStatusError: HTTP <status>`, shown under the field by the panel; until 0.20.0 it was an
`http.ClientException` saying `Tolgee answered <status> to a save of "<key>"`). Neither the key nor what Tolgee said is kept.

The recorded keys are cleared when the locale or the route changes.

## Tests

`translationEditor` is the provider the panel saves through (`TolgeeEditor.fromEnvironment(transport:)` over the
`tolgeeEditorTransport` provider by default, which is `null` outside an in-context build). **`tolgeeEditorTransport` has
no default** (since 0.21.0; the editor made its own `http.Client` until 0.20.0): override it with the app's
`HttpTransport` in the debug configuration that turns in-context editing on. It is read only by an in-context build that
has a key, so a release build never reads it; a build that does read it without the override throws a `StateError`:

```text
tolgeeEditorTransport has no default: override it in the ProviderScope with the app's HttpTransport in the build that turns in-context editing on.
```

`package:fespalier_tolgee/testing.dart` has `RecordingEditor`, a
`TranslationEditor` that records `(key, locale, text)` instead of calling Tolgee:

```dart
// a fragment: override it, open the panel, save, then read the recording
final editor = RecordingEditor();
final overrides = [translationEditor.overrideWithValue(editor)];
// ... after a save in the panel: expect(editor.saved.single.key, 'products.title');
```

## Where the code is

`packages/fespalier_tolgee/lib/src/in_context/editor.dart` (`kTolgeeInContext`, `TranslationEditor`, `TolgeeEditor`,
`tolgeeEditorTransport`, `translationEditor`) and `panel.dart`; `scope.dart` decides whether the panel is built.
