import 'package:features/app.g.dart';
import 'package:fespalier/fespalier.dart';

/// A link into the middle opens where the user had got to: the first step not done, when the link
/// is a step past it (from the flow on screen, else from the draft).
GuardResult guard(Ref ref, {required Uri uri}) =>
    SignupSection.resume(ref, uri: uri);
