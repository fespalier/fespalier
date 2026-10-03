import 'package:shop/app.main.g.dart';

// The generated main() (lib/app.main.g.dart) runs lib/app/app.dart. /checkout and
// /products/:id are deferred routes: on the web each is a chunk the browser fetches when it is
// needed (or ahead of time, when a link to it is hovered). Elsewhere the generated main() loads
// the code before the first frame, so a page never shows loading.dart for it.
Future<void> main() => AppMain.run();
