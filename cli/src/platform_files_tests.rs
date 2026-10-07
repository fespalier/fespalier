//! `fsp links` editing `AndroidManifest.xml` and the entitlements: where the filters go, that a
//! second run changes nothing, that only what is between the markers (or the `applinks:`
//! entries) moves, and every message of the files that can't be edited.
//!
//! The fixtures are in `tests/fixtures/links/`: the manifest `flutter create` writes, and an
//! entitlements file as Xcode lays it out.

use crate::config::{Links, Pubspec};
use crate::platform_files::{self as pf, Was};

const MANIFEST: &str = include_str!("../tests/fixtures/links/AndroidManifest.xml");
const ENTITLEMENTS: &str = include_str!("../tests/fixtures/links/Runner.entitlements");
const EMPTY_DICT: &str = include_str!("../tests/fixtures/links/Empty.entitlements");
const PATH: &str = "android/app/src/main/AndroidManifest.xml";
const PLIST: &str = "ios/Runner/Runner.entitlements";

const FILTERS: &str = "<intent-filter android:autoVerify=\"true\">\n    <action android:name=\"android.intent.action.VIEW\" />\n    <data android:scheme=\"https\" />\n    <data android:host=\"shop.example.com\" />\n</intent-filter>\n";

fn domains() -> Vec<String> {
    vec!["shop.example.com".into(), "www.shop.example.com".into()]
}

fn cfg(lines: &[&str]) -> Links {
    let body: String = lines.iter().map(|l| format!("    {l}\n")).collect();
    Pubspec::parse(&format!("name: demo\nfespalier:\n  links:\n{body}"))
        .unwrap()
        .config
        .links
        .unwrap()
        .validate()
        .unwrap()
}

fn edited(current: &str) -> (String, Was) {
    pf::edit_manifest(PATH, current, FILTERS).unwrap()
}

fn manifest_error(current: &str) -> String {
    format!(
        "{:#}",
        pf::edit_manifest(PATH, current, FILTERS).unwrap_err()
    )
}

fn edit_plist(path: &str, current: &str, domains: &[String]) -> anyhow::Result<String> {
    pf::edit_entitlements(path, current, domains).map(|r| r.0)
}

fn plist_error(current: &str) -> String {
    format!("{:#}", edit_plist(PLIST, current, &domains()).unwrap_err())
}

#[test]
fn the_filters_go_before_the_end_of_the_launcher_activity() {
    let (text, was) = edited(MANIFEST);
    assert_eq!(was, Was::NoMarkers);
    let expected = MANIFEST.replacen(
        "        </activity>\n",
        &format!(
            "            <!-- fsp links: begin. Written from lib/app by `fsp links`; change links: in pubspec.yaml, not these lines. -->\n\
             {}            <!-- fsp links: end -->\n        </activity>\n",
            FILTERS
                .lines()
                .map(|l| format!("            {l}\n"))
                .collect::<String>()
        ),
        1,
    );
    assert_eq!(text, expected);
    // Everything else is the file's own.
    assert!(text.starts_with(&MANIFEST[..MANIFEST.find("        </activity>").unwrap()]));
    assert!(text.ends_with("</queries>\n</manifest>\n"));
}

#[test]
fn a_second_run_changes_no_byte() {
    let (once, _) = edited(MANIFEST);
    let (twice, was) = edited(&once);
    assert_eq!(was, Was::Current);
    assert_eq!(twice, once);
}

#[test]
fn only_what_is_between_the_markers_changes() {
    let (once, _) = edited(MANIFEST);
    let other = "<intent-filter>\n    <data android:scheme=\"myshop\" />\n</intent-filter>\n";
    let (text, was) = pf::edit_manifest(PATH, &once, other).unwrap();
    assert_eq!(was, Was::OutOfDate);
    let (a, b) = (
        once.find("<!-- fsp links: begin").unwrap(),
        once.find("<!-- fsp links: end").unwrap(),
    );
    let after_begin = once[a..].find('\n').unwrap() + a + 1;
    let line_of_end = once[..b].rfind('\n').unwrap() + 1;
    // The same bytes before the first filter line and from the end marker's line on.
    assert_eq!(text[..after_begin], once[..after_begin]);
    assert!(text.ends_with(&once[line_of_end..]));
    assert!(text.contains(
        "            <intent-filter>\n                <data android:scheme=\"myshop\" />"
    ));
    assert!(!text.contains("shop.example.com"));
}

#[test]
fn markers_written_by_hand_are_kept_as_they_are() {
    let hand = MANIFEST.replace(
        "        </activity>\n",
        "          <!-- fsp links: begin -->\n          <!-- fsp links: end -->\n        </activity>\n",
    );
    let (text, was) = edited(&hand);
    assert_eq!(was, Was::OutOfDate);
    assert!(text.contains("          <!-- fsp links: begin -->\n          <intent-filter android:autoVerify=\"true\">\n"));
    assert!(text.contains("          </intent-filter>\n          <!-- fsp links: end -->\n"));
    assert_eq!(edited(&text), (text.clone(), Was::Current));
}

#[test]
fn an_alias_and_a_comment_are_not_the_launcher_activity() {
    let alias = "        <activity-alias android:name=\".Alias\" android:targetActivity=\".MainActivity\">\n            <intent-filter>\n                <action android:name=\"android.intent.action.MAIN\"/>\n            </intent-filter>\n        </activity-alias>\n";
    let with_alias = MANIFEST.replacen(
        "        <!-- Don't delete",
        &format!("{alias}        <!-- Don't delete"),
        1,
    );
    let (text, _) = edited(&with_alias);
    // The filters are in the real activity, not before `</activity-alias>`.
    let begin = text.find("fsp links: begin").unwrap();
    assert!(begin < text.find("<activity-alias").unwrap());

    let commented = MANIFEST.replace(
        "<action android:name=\"android.intent.action.MAIN\"/>",
        "<!-- <action android:name=\"android.intent.action.MAIN\"/> -->",
    );
    assert!(manifest_error(&commented).contains("no single <activity>"));
}

#[test]
fn two_launcher_activities_or_none_ask_for_markers_by_hand() {
    let second = "        <activity android:name=\".Other\">\n            <intent-filter>\n                <action android:name=\"android.intent.action.MAIN\"/>\n            </intent-filter>\n        </activity>\n";
    let two = MANIFEST.replacen(
        "        <!-- Don't delete",
        &format!("{second}        <!-- Don't delete"),
        1,
    );
    let expected = format!(
        "{PATH}: no single <activity> with the MAIN/LAUNCHER intent filter to put the link filters in; add `<!-- fsp links: begin -->` and `<!-- fsp links: end -->` on two lines inside the activity that opens links, and run `fsp links` again"
    );
    assert_eq!(manifest_error(&two), expected);
    let none = MANIFEST.replace("android.intent.action.MAIN", "android.intent.action.OTHER");
    assert_eq!(manifest_error(&none), expected);
    assert_eq!(manifest_error("<manifest>"), expected);
    // Two filters of one activity are still one activity.
    let twice = MANIFEST.replacen(
        "            </intent-filter>\n        </activity>",
        "            </intent-filter>\n            <intent-filter>\n                <action android:name=\"android.intent.action.MAIN\"/>\n            </intent-filter>\n        </activity>",
        1,
    );
    assert_eq!(edited(&twice).1, Was::NoMarkers);
}

#[test]
fn markers_must_come_once_each_begin_first_and_on_their_own_lines() {
    let expected = format!(
        "{PATH}: `<!-- fsp links: begin -->` and `<!-- fsp links: end -->` must each appear once, the begin first"
    );
    let (once, _) = edited(MANIFEST);
    let begin_only = once.replace("            <!-- fsp links: end -->\n", "");
    assert_eq!(manifest_error(&begin_only), expected);
    let twice = once.replace(
        "        </activity>\n",
        "            <!-- fsp links: end -->\n        </activity>\n",
    );
    assert_eq!(manifest_error(&twice), expected);
    let swapped = once
        .replace("fsp links: begin.", "fsp links: TMP.")
        .replace("fsp links: end", "fsp links: begin")
        .replace("fsp links: TMP.", "fsp links: end");
    assert_eq!(manifest_error(&swapped), expected);
    let inline = once.replace(
        "<!-- fsp links: end -->",
        "<meta-data android:name=\"x\" android:value=\"y\" /><!-- fsp links: end -->",
    );
    assert_eq!(manifest_error(&inline), expected);
}

#[test]
fn crlf_line_endings_are_kept() {
    let crlf = MANIFEST.replace('\n', "\r\n");
    let (text, was) = edited(&crlf);
    assert_eq!(was, Was::NoMarkers);
    assert!(
        !text.replace("\r\n", "").contains('\n'),
        "a bare LF came in"
    );
    assert_eq!(edited(&text), (text.clone(), Was::Current));
    let (back, _) = pf::edit_manifest(PATH, &text, "<intent-filter />\n").unwrap();
    assert!(!back.replace("\r\n", "").contains('\n'));
}

#[test]
fn a_gt_in_a_quoted_value_does_not_end_the_tag() {
    let odd = MANIFEST.replacen(
        "android:icon=\"@mipmap/ic_launcher\"",
        "android:icon=\"@mipmap/ic_launcher\" tools:x=\"a>b\"",
        1,
    );
    assert_eq!(edited(&odd).1, Was::NoMarkers);
}

#[test]
fn a_filter_of_our_own_outside_the_markers_is_warned_about() {
    let links = cfg(&[
        "domains: [shop.example.com]",
        "scheme: myshop",
        "scheme_host: false",
        "android_package: com.example.shop",
        &format!("android_sha256: [\"{}\"]", "AB:".repeat(31) + "AB"),
    ]);
    let hand = MANIFEST.replace(
        "        </activity>\n",
        "            <intent-filter>\n                <action android:name=\"android.intent.action.VIEW\"/>\n                <data android:scheme=\"https\" android:host=\"Shop.Example.com\"/>\n            </intent-filter>\n            <intent-filter>\n                <action android:name=\"android.intent.action.VIEW\"/>\n                <data android:scheme=\"myshop\"/>\n            </intent-filter>\n            <intent-filter>\n                <action android:name=\"android.intent.action.VIEW\"/>\n                <data android:scheme=\"https\" android:host=\"other.example.com\"/>\n            </intent-filter>\n        </activity>\n",
    );
    let warnings = pf::foreign_filters(PATH, &hand, &links);
    assert_eq!(warnings.len(), 2, "{warnings:?}");
    let line = |needle: &str| hand[..hand.find(needle).unwrap()].matches('\n').count() + 1;
    let first = line("<data android:scheme=\"https\" android:host=\"Shop") - 2;
    assert_eq!(
        warnings[0],
        format!(
            "{PATH}:{first}: an <intent-filter> for `shop.example.com` outside the fsp links markers; remove it, `fsp links` writes that filter now"
        )
    );
    assert!(
        warnings[1].contains("for `myshop://` outside"),
        "{warnings:?}"
    );
    // Inside the markers, and the launcher filter, are fine.
    let (ours, _) = edited(MANIFEST);
    assert!(pf::foreign_filters(PATH, &ours, &links).is_empty());
    assert!(pf::foreign_filters(PATH, MANIFEST, &links).is_empty());
}

// --- the plist -----------------------------------------------------------------------

fn bare(body: &str) -> String {
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>\n{body}</dict>\n</plist>\n"
    )
}

#[test]
fn an_absent_key_is_added_before_the_end_of_the_dict() {
    let current = bare("\t<key>aps-environment</key>\n\t<string>development</string>\n");
    let text = edit_plist(PLIST, &current, &domains()).unwrap();
    assert_eq!(
        text,
        bare(
            "\t<key>aps-environment</key>\n\t<string>development</string>\n\t<key>com.apple.developer.associated-domains</key>\n\t<array>\n\t\t<string>applinks:shop.example.com</string>\n\t\t<string>applinks:www.shop.example.com</string>\n\t</array>\n"
        )
    );
    assert_eq!(edit_plist(PLIST, &text, &domains()).unwrap(), text);
}

#[test]
fn an_existing_key_keeps_its_other_entries_and_puts_ours_after_them() {
    let text = edit_plist(PLIST, ENTITLEMENTS, &domains()).unwrap();
    assert_eq!(
        text,
        ENTITLEMENTS.replace(
            "\t\t<string>webcredentials:shop.example.com</string>\n\t\t<string>applinks:old.example.com</string>\n",
            "\t\t<string>webcredentials:shop.example.com</string>\n\t\t<string>applinks:shop.example.com</string>\n\t\t<string>applinks:www.shop.example.com</string>\n"
        )
    );
    assert_eq!(edit_plist(PLIST, &text, &domains()).unwrap(), text);
    // An application's own order of things is only touched where it has to be.
    let only = edit_plist(PLIST, &text, &["shop.example.com".to_string()]).unwrap();
    assert!(!only.contains("www.shop") && only.contains("webcredentials:shop.example.com"));
}

#[test]
fn an_empty_array_and_an_empty_dict_are_filled() {
    let one = &domains()[..1];
    for empty in ["<array/>", "<array></array>", "<array>\n\t</array>"] {
        let current = bare(&format!(
            "\t<key>com.apple.developer.associated-domains</key>\n\t{empty}\n"
        ));
        let text = edit_plist(PLIST, &current, one).unwrap();
        assert_eq!(
            text,
            bare(
                "\t<key>com.apple.developer.associated-domains</key>\n\t<array>\n\t\t<string>applinks:shop.example.com</string>\n\t</array>\n"
            ),
            "{empty}"
        );
    }
    let text = edit_plist(PLIST, EMPTY_DICT, one).unwrap();
    assert_eq!(
        text,
        EMPTY_DICT.replace(
            "<dict/>",
            "<dict>\n\t<key>com.apple.developer.associated-domains</key>\n\t<array>\n\t\t<string>applinks:shop.example.com</string>\n\t</array>\n</dict>"
        )
    );
    assert_eq!(edit_plist(PLIST, &text, one).unwrap(), text);
}

#[test]
fn a_new_file_is_a_whole_plist_and_crlf_is_kept() {
    let text = pf::new_entitlements(&domains());
    assert!(text.starts_with("<?xml version=\"1.0\""));
    assert!(!text.contains("<!-- "), "{text}");
    assert!(text.contains("\t\t<string>applinks:www.shop.example.com</string>\n"));
    // What `fsp` writes is what it leaves alone.
    assert_eq!(edit_plist(PLIST, &text, &domains()).unwrap(), text);

    let crlf = ENTITLEMENTS.replace('\n', "\r\n");
    let edited = edit_plist(PLIST, &crlf, &domains()).unwrap();
    assert!(!edited.replace("\r\n", "").contains('\n'));
}

#[test]
fn what_is_not_an_editable_plist_says_so() {
    let expected = format!(
        "{PLIST}: not an XML property list with a <dict> at the top; fsp links edits only `com.apple.developer.associated-domains` in it"
    );
    for bad in [
        "",
        "not xml at all",
        "<plist version=\"1.0\"><array/></plist>",
        "<plist version=\"1.0\"><dict></plist>",
        "<dict/>",
        "<plist><dict/></plist><plist><dict/></plist>",
    ] {
        assert_eq!(plist_error(bad), expected, "{bad:?}");
    }
    let not_array = bare(
        "\t<key>com.apple.developer.associated-domains</key>\n\t<string>applinks:x</string>\n",
    );
    assert_eq!(
        plist_error(&not_array),
        format!(
            "{PLIST}: `com.apple.developer.associated-domains` is not an <array>; fix it by hand, fsp links only edits an array"
        )
    );
    let no_value = bare("\t<key>com.apple.developer.associated-domains</key>\n");
    assert!(plist_error(&no_value).contains("is not an <array>"));
}

// --- what the review of the first version found --------------------------------------

fn tempdir_with(files: &[(&str, &[u8])]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    for (path, bytes) in files {
        let full = dir.path().join(path);
        std::fs::create_dir_all(full.parent().unwrap()).unwrap();
        std::fs::write(full, bytes).unwrap();
    }
    dir
}

fn both() -> Links {
    cfg(&[
        "domains: [shop.example.com]",
        "android_package: com.example.shop",
        &format!("android_sha256: [\"{}\"]", "AB:".repeat(31) + "AB"),
        "android_manifest: android/app/src/main/AndroidManifest.xml",
        "ios_app_id: ABCDE12345.com.example.shop",
        "ios_entitlements: ios/Runner/Runner.entitlements",
    ])
}

#[test]
fn a_file_that_is_not_utf8_is_refused_not_rewritten() {
    let mut bytes = MANIFEST.as_bytes().to_vec();
    bytes.splice(0..0, b"<!-- caf\xE9 -->\n".iter().copied());
    let dir = tempdir_with(&[(PATH, &bytes), (PLIST, ENTITLEMENTS.as_bytes())]);
    let e = format!("{:#}", pf::plan(dir.path(), &both(), FILTERS).unwrap_err());
    assert_eq!(
        e,
        format!("{PATH} is not UTF-8; fsp links edits only UTF-8 files")
    );
    let dir = tempdir_with(&[(PATH, MANIFEST.as_bytes()), (PLIST, b"<plist>\xFF</plist>")]);
    let e = format!("{:#}", pf::plan(dir.path(), &both(), FILTERS).unwrap_err());
    assert_eq!(
        e,
        format!("{PLIST} is not UTF-8; fsp links edits only UTF-8 files")
    );
}

#[test]
fn a_main_action_outside_an_intent_filter_is_not_a_launcher() {
    let queries = MANIFEST.replace(
        "<action android:name=\"android.intent.action.PROCESS_TEXT\"/>",
        "<action android:name=\"android.intent.action.MAIN\"/>",
    );
    assert_eq!(edited(&queries).1, Was::NoMarkers);
}

#[test]
fn markers_outside_an_activity_are_an_error() {
    let in_app = MANIFEST.replace(
        "        <!-- Don't delete",
        "        <!-- fsp links: begin -->\n        <!-- fsp links: end -->\n        <!-- Don't delete",
    );
    let e = manifest_error(&in_app);
    assert_eq!(
        e,
        format!(
            "{PATH}: the fsp links markers are not inside an <activity>, where Android reads intent filters; move both onto lines of their own inside the activity that opens links"
        )
    );
    // One in the activity and one outside it is as wrong.
    let split = MANIFEST
        .replace(
            "            <meta-data\n              android:name=\"io.flutter.embedding.android.NormalTheme\"",
            "            <!-- fsp links: begin -->\n            <meta-data\n              android:name=\"io.flutter.embedding.android.NormalTheme\"",
        )
        .replace(
            "        <!-- Don't delete",
            "        <!-- fsp links: end -->\n        <!-- Don't delete",
        );
    assert!(manifest_error(&split).contains("not inside an <activity>"));
}

#[test]
fn a_comment_that_only_starts_like_the_begin_marker_is_not_one() {
    let note = MANIFEST.replace(
        "        <!-- Don't delete",
        "        <!-- fsp links: beginning of notes -->\n        <!-- Don't delete",
    );
    assert_eq!(edited(&note).1, Was::NoMarkers);
}

#[test]
fn a_tab_indented_manifest_gets_tab_indented_markers() {
    let tabs = MANIFEST.replace("    ", "\t");
    let (text, _) = edited(&tabs);
    assert!(text.contains("\t\t\t<!-- fsp links: begin."), "{text}");
    assert!(!text.contains("\t    "), "mixed indentation");
    assert_eq!(edited(&text).1, Was::Current);
}

#[test]
fn a_filter_that_tools_removes_is_not_ours() {
    let links = both();
    let hand = MANIFEST.replace(
        "        </activity>\n",
        "            <intent-filter tools:node=\"remove\">\n                <action android:name=\"android.intent.action.VIEW\"/>\n                <data android:scheme=\"https\" android:host=\"shop.example.com\"/>\n            </intent-filter>\n        </activity>\n",
    );
    assert!(pf::foreign_filters(PATH, &hand, &links).is_empty());
}

#[test]
fn the_build_setting_may_spell_the_path_in_any_of_xcodes_ways() {
    for value in [
        "Runner/Runner.entitlements",
        "\"$(SRCROOT)/Runner/Runner.entitlements\"",
        "\"${SRCROOT}/Runner/Runner.entitlements\"",
        "\"$(PROJECT_DIR)/Runner/Runner.entitlements\"",
        "\"$(SOURCE_ROOT)/Runner/Runner.entitlements\"",
        "./Runner/Runner.entitlements",
    ] {
        let pbx = format!("\t\t\t\tCODE_SIGN_ENTITLEMENTS = {value};\n");
        assert!(
            pf::pbxproj_references(&pbx, "Runner/Runner.entitlements"),
            "{value}"
        );
    }
    assert!(!pf::pbxproj_references(
        "CODE_SIGN_ENTITLEMENTS = Runner/Other.entitlements;",
        "Runner/Runner.entitlements"
    ));
}

#[test]
fn only_our_applinks_items_are_rewritten_and_the_rest_is_byte_for_byte() {
    let current = bare(
        "\t<key>com.apple.developer.associated-domains</key>\n\t<array>\n\t\t<!-- keep me -->\n\t\t<string>webcredentials:shop.example.com</string>\n\t\t\t<string>applinks:old.example.com?mode=developer</string>\n\t\t  <string>applinks:shop.example.com</string>\n\t\t<!-- and me -->\n\t</array>\n",
    );
    let (text, removed) = pf::edit_entitlements(PLIST, &current, &domains()[..1]).unwrap();
    assert_eq!(
        text,
        bare(
            "\t<key>com.apple.developer.associated-domains</key>\n\t<array>\n\t\t<!-- keep me -->\n\t\t<string>webcredentials:shop.example.com</string>\n\t\t<!-- and me -->\n\t\t<string>applinks:shop.example.com</string>\n\t</array>\n"
        )
    );
    assert_eq!(removed.len(), 1, "{removed:?}");
    assert_eq!(
        removed[0],
        format!(
            "{PLIST}: removed `applinks:old.example.com?mode=developer` from `com.apple.developer.associated-domains`: fsp links owns every applinks: entry, and `old.example.com` is not in `fespalier.links.domains`"
        )
    );
    // Our own entries already there are not a warning, and the file is the same bytes.
    let (again, none) = pf::edit_entitlements(PLIST, &text, &domains()[..1]).unwrap();
    assert_eq!((again, none.len()), (text, 0));
}

#[test]
fn a_missing_entitlements_folder_is_an_error_not_a_new_ios_tree() {
    let dir = tempdir_with(&[(PATH, MANIFEST.as_bytes())]);
    let e = format!("{:#}", pf::plan(dir.path(), &both(), FILTERS).unwrap_err());
    assert_eq!(
        e,
        format!(
            "{PLIST}: the folder ios/Runner does not exist; fsp links writes the file, not the iOS project: run `flutter create --platforms ios .`, or create the folder"
        )
    );
    let dir = tempdir_with(&[(PATH, MANIFEST.as_bytes()), ("ios/Runner/Info.plist", b"x")]);
    let (files, _) = pf::plan(dir.path(), &both(), FILTERS).unwrap();
    assert!(files.iter().any(|f| f.path == PLIST && f.created));
}
