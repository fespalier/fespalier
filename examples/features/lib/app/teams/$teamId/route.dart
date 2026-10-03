import 'package:fespalier/fespalier.dart';

/// The data of /teams/:teamId (the section's) and of everything below it, such as
/// members/$member, is fresh for 30 seconds. After that the next read (a page opening in the
/// section, a link preloading) shows it and loads it again. An action's `invalidates` is not a
/// read: it loads again at once, whatever this says.
const freshness = Freshness(staleTime: Duration(seconds: 30));
