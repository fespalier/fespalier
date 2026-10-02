// The checkout page's code is a chunk of its own on the web (`flutter build web`): a visitor who
// never gets to the checkout never downloads it. The guard still runs first, from eager code.
const deferred = true;
