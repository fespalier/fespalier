import 'package:fespalier/fespalier.dart';
import 'package:fespalier_forms/fespalier_forms.dart';
import 'package:flutter/widgets.dart';

/// Asked once for the whole flow: it is the `onExit` of each step, and a navigation that stays in
/// `/signup` (next, back, a step edited from the review) passes without asking. The flow is a
/// `LeaveSource` of every step page by itself.
LeaveResult leave(BuildContext context, Ref ref, {required PageLeave page}) =>
    leaveIfClean(context, ref, page);
