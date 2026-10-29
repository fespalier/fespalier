/// What tests use from fespalier_frb (since 0.13.0). [FakeChangeSource] is fespalier_stream's since
/// 0.25.0, re-exported here.
library;

export 'package:fespalier_frb/fespalier_frb.dart'
    show
        Change,
        ChangeBudget,
        ChangeCodec,
        ChangeFeed,
        InvalidationRule,
        InvalidationTable,
        UnknownChange;
export 'package:fespalier_stream/testing.dart' show FakeChangeSource;
