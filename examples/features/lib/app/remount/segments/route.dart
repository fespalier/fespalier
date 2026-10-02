import 'package:fespalier/fespalier.dart';

/// A new page when a segment changes (`/remount/segments/1` to `/2`), the same one when
/// only the query does (`?page=2`): what a page that keeps its state in the URL needs,
/// like the search page's `copyWith(page: ...)`.
const remount = Remount.onSegments;
