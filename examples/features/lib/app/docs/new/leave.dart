import 'package:features/new_doc.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

/// Asked before `/docs/new` goes: popped, replaced or navigated away from, by the Android back
/// or the browser's too (since 0.11.0). A page with nothing to lose lets it go at once (a `bool`
/// returned directly stays synchronous); otherwise a bottom sheet asks, and `false` keeps the
/// page. The page registered what it holds as a `LeaveSource`, which `page.isDirty` reports.
///
/// It belongs to this folder's page alone: `/docs/*rest` beside it is not asked.
LeaveResult leave(
  BuildContext context,
  Ref ref, {
  required PageLeave page,
}) {
  if (!page.isDirty) return true;
  return askToDiscard(context).then((discard) {
    if (discard) page.discard();
    return discard;
  });
}
