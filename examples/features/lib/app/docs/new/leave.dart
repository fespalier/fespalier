import 'package:features/new_doc.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

/// Asked before `/docs/new` goes: popped, replaced or navigated away from, by the Android back
/// or the browser's too (since 0.11.0). Nothing typed lets it go at once, and a `bool` returned
/// directly stays synchronous; otherwise a bottom sheet asks, and `false` keeps the page.
///
/// It belongs to this folder's page alone: `/docs/*rest` beside it is not asked.
LeaveResult leave(
  BuildContext context,
  Ref ref, {
  required PageLeave page,
}) {
  if (ref.read(newDocDraft).isEmpty) return true;
  return askToDiscard(context);
}
