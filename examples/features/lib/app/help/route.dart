// `help/` also answers /aide (fr) and /hilfe (de). The typed route, the page and its data stay
// single: `HelpRoute().location` is /help, and `HelpRoute().locationFor('fr')` is /aide.
// Paths match in any case in this app (see pubspec.yaml), spellings included.
const paths = {'fr': 'aide', 'de': 'hilfe'};
