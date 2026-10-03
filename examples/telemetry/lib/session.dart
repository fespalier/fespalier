import 'package:fespalier/fespalier.dart';

/// Whether somebody is signed in. The guard of /settings reads it; a real app would watch its
/// session here.
final Provider<bool> signedIn = Provider<bool>((ref) => true);
