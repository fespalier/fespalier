// Spellings may have letters beyond ASCII: /guide also answers /führer (de) and /руководство (ru).
// go_router matches the percent-encoded path, so `fsp gen` writes each one encoded
// (`%C3%BChrer`); a deep link may be raw or encoded, and `locationFor` writes it encoded.
const paths = {'de': 'führer', 'ru': 'руководство'};
