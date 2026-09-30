import 'package:fespalier/fespalier.dart';
import 'package:tabs/profile_draft.dart';

/// `fsp gen` hands this to `AppRoutes.router()` as `GoRouter(extraCodec:)`.
/// go_router saves an `extra` with the location, for state restoration and the
/// web's history, but only if it is JSON: without a codec, a page opened with
/// `extra: ProfileDraft(...)` gets `null` back after a restart or a reload.
///
/// Each type says how it becomes JSON and back. Anything left out (or that
/// can't be read again later) comes back as `null`, never as an error.
final extraCodec = ExtraCodec({
  ProfileDraft: (
    toJson: (ProfileDraft d) => d.toJson(),
    fromJson: ProfileDraft.fromJson,
  ),
});
