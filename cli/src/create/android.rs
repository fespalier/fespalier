//! The one edit `fsp create` makes to a file `flutter create` wrote: the Android `minSdk`.
//!
//! Flutter's own default is `flutter.minSdkVersion`, 21 up to Flutter 3.32 and 24 from 3.35 (read
//! in `FlutterExtension.kt` of both SDKs). A plugin that needs 24 (`flutter_secure_storage`, the
//! token store of `fespalier_auth`) fails the Android build on the older default, so the line is
//! made `maxOf(flutter.minSdkVersion, N)`: the Flutter default stays what raises it later, and
//! nothing lowers it. The line is marked, so the edit is recognisable and idempotent.

/// The line `flutter create` writes in `android/app/build.gradle.kts`.
const DEFAULT_LINE: &str = "minSdk = flutter.minSdkVersion";

/// The comment that marks the edit.
const MARK: &str = "// fsp create:";

/// `gradle` (the Kotlin DSL file) with `minSdk` at least `min`. `None` when the file has no
/// `minSdk = flutter.minSdkVersion` line to change (already edited, or a shape this does not
/// know): the caller then says what to do by hand.
#[must_use]
pub fn raise_min_sdk(gradle: &str, min: u32) -> Option<String> {
    let mut changed = false;
    let lines: Vec<String> = gradle
        .split('\n')
        .map(|line| {
            if !changed && line.trim() == DEFAULT_LINE {
                changed = true;
                let indent = &line[..line.len() - line.trim_start().len()];
                format!(
                    "{indent}minSdk = maxOf(flutter.minSdkVersion, {min}) {MARK} flutter_secure_storage needs {min}"
                )
            } else {
                line.to_string()
            }
        })
        .collect();
    changed.then(|| lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const GRADLE: &str = "android {\n    defaultConfig {\n        minSdk = flutter.minSdkVersion\n        targetSdk = flutter.targetSdkVersion\n    }\n}\n";

    #[test]
    fn it_raises_the_flutter_default_and_keeps_the_rest() {
        let out = raise_min_sdk(GRADLE, 24).unwrap();
        assert!(
            out.contains("        minSdk = maxOf(flutter.minSdkVersion, 24) // fsp create:"),
            "{out}"
        );
        assert!(out.contains("        targetSdk = flutter.targetSdkVersion\n"));
        assert!(out.ends_with("}\n"));
        assert_eq!(out.lines().count(), GRADLE.lines().count());
    }

    #[test]
    fn it_does_nothing_to_a_file_it_does_not_know_or_has_edited() {
        assert_eq!(raise_min_sdk("android {}\n", 24), None);
        let once = raise_min_sdk(GRADLE, 24).unwrap();
        assert_eq!(raise_min_sdk(&once, 24), None);
        assert_eq!(raise_min_sdk("minSdk = 21\n", 24), None);
    }
}
