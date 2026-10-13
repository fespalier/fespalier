import 'package:fespalier/fespalier.dart';
import 'package:fespalier_forms/fespalier_forms.dart';
import 'package:flutter/widgets.dart';

/// Asked before /nickname goes, whatever takes it away: a link, the back button, the browser's
/// back (since 0.11.0). The form is a `LeaveSource` of the page by itself, so a clean form goes
/// at once (a `bool`, so no `Future`) and one with unsaved changes asks in a bottom sheet:
/// "Keep editing", "Discard", or "Keep as draft" (the page's `useForm` has a `draft:`). Tests
/// answer it with `LeavePrompts.answer`.
LeaveResult leave(BuildContext context, Ref ref, {required PageLeave page}) =>
    leaveIfClean(context, ref, page);
