/// What a save too large for a storage's `maxSize` fails with (since 0.9.0). fespalier prints it after
/// `fespalier: dataCache of <name> could not save:`; the route keeps working and nothing is saved for it.
final class DataEntryTooLarge implements Exception {
  /// A value of [size] for [key], over [maxSize].
  const DataEntryTooLarge(this.key, this.size, this.maxSize);

  /// The dataCache key (`fespalier:products/$id[42]`).
  final String key;

  /// What it would take, in characters (`String.length`), header included.
  final int size;

  /// The storage's budget.
  final int maxSize;

  @override
  String toString() =>
      'fespalier_storage: the value saved under $key is $size characters, more than maxSize ($maxSize), so it was not saved';
}
