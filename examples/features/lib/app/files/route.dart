/// pubspec.yaml says paths match in any case; this folder and everything below it
/// opt out, so `/files/README.md` isn't `/files/readme.md`, and `/Files` isn't found.
/// The nearest route.dart wins. It is read when the tree is generated, so it has to
/// be a `true` or `false` literal.
const caseSensitive = true;
