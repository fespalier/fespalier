/// Debug-only in-context editing for fespalier_tolgee (since 0.10.0): `kTolgeeInContext`, the
/// `TranslationEditor` the panel saves through, and `TolgeeEditor`, which calls Tolgee's REST API.
///
/// The main library references this under `if (kTolgeeInContext)`, so a release build compiles it
/// out. The API key is read from `--dart-define=TOLGEE_API_KEY` in one place, behind that constant.
library;

export 'src/in_context/editor.dart'
    show TolgeeEditor, TranslationEditor, kTolgeeInContext, translationEditor;
