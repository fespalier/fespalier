// The URL is below `refund/`, but this route is not a child of the refund page: it is
// its sibling, `GoRoute(path: 'refund/confirm')` beside `GoRoute(path: 'refund')`, so the
// refund page is not built (and its data.dart is not read) when this one is opened.
// `refund/receipt` has no such file: it nests, and a deep link builds the refund page too.
const nest = false;
