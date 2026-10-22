// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'shared_types.dart';

class StringFilterMapper extends ClassMapperBase<StringFilter> {
  StringFilterMapper._();

  static StringFilterMapper? _instance;
  static StringFilterMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = StringFilterMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'StringFilter';

  static String? _$eq(StringFilter v) => v.eq;
  static const Field<StringFilter, String> _f$eq = Field('eq', _$eq, opt: true);
  static String? _$ne(StringFilter v) => v.ne;
  static const Field<StringFilter, String> _f$ne = Field('ne', _$ne, opt: true);
  static List<String>? _$in$(StringFilter v) => v.in$;
  static const Field<StringFilter, List<String>> _f$in$ = Field(
    'in\$',
    _$in$,
    opt: true,
  );
  static String? _$lt(StringFilter v) => v.lt;
  static const Field<StringFilter, String> _f$lt = Field('lt', _$lt, opt: true);
  static String? _$lte(StringFilter v) => v.lte;
  static const Field<StringFilter, String> _f$lte = Field(
    'lte',
    _$lte,
    opt: true,
  );
  static String? _$gt(StringFilter v) => v.gt;
  static const Field<StringFilter, String> _f$gt = Field('gt', _$gt, opt: true);
  static String? _$gte(StringFilter v) => v.gte;
  static const Field<StringFilter, String> _f$gte = Field(
    'gte',
    _$gte,
    opt: true,
  );
  static String? _$contains(StringFilter v) => v.contains;
  static const Field<StringFilter, String> _f$contains = Field(
    'contains',
    _$contains,
    opt: true,
  );
  static String? _$startsWith(StringFilter v) => v.startsWith;
  static const Field<StringFilter, String> _f$startsWith = Field(
    'startsWith',
    _$startsWith,
    opt: true,
  );
  static bool? _$isNull(StringFilter v) => v.isNull;
  static const Field<StringFilter, bool> _f$isNull = Field(
    'isNull',
    _$isNull,
    opt: true,
  );

  @override
  final MappableFields<StringFilter> fields = const {
    #eq: _f$eq,
    #ne: _f$ne,
    #in$: _f$in$,
    #lt: _f$lt,
    #lte: _f$lte,
    #gt: _f$gt,
    #gte: _f$gte,
    #contains: _f$contains,
    #startsWith: _f$startsWith,
    #isNull: _f$isNull,
  };

  static StringFilter _instantiate(DecodingData data) {
    return StringFilter(
      eq: data.dec(_f$eq),
      ne: data.dec(_f$ne),
      in$: data.dec(_f$in$),
      lt: data.dec(_f$lt),
      lte: data.dec(_f$lte),
      gt: data.dec(_f$gt),
      gte: data.dec(_f$gte),
      contains: data.dec(_f$contains),
      startsWith: data.dec(_f$startsWith),
      isNull: data.dec(_f$isNull),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin StringFilterMappable {
  StringFilterCopyWith<StringFilter, StringFilter, StringFilter> get copyWith =>
      _StringFilterCopyWithImpl<StringFilter, StringFilter>(
        this as StringFilter,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return StringFilterMapper.ensureInitialized().equalsValue(
      this as StringFilter,
      other,
    );
  }

  @override
  int get hashCode {
    return StringFilterMapper.ensureInitialized().hashValue(
      this as StringFilter,
    );
  }
}

extension StringFilterValueCopy<$R, $Out>
    on ObjectCopyWith<$R, StringFilter, $Out> {
  StringFilterCopyWith<$R, StringFilter, $Out> get $asStringFilter =>
      $base.as((v, t, t2) => _StringFilterCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class StringFilterCopyWith<$R, $In extends StringFilter, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, String, ObjectCopyWith<$R, String, String>>? get in$;
  $R call({
    String? eq,
    String? ne,
    List<String>? in$,
    String? lt,
    String? lte,
    String? gt,
    String? gte,
    String? contains,
    String? startsWith,
    bool? isNull,
  });
  StringFilterCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _StringFilterCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, StringFilter, $Out>
    implements StringFilterCopyWith<$R, StringFilter, $Out> {
  _StringFilterCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<StringFilter> $mapper =
      StringFilterMapper.ensureInitialized();
  @override
  ListCopyWith<$R, String, ObjectCopyWith<$R, String, String>>? get in$ =>
      $value.in$ != null
          ? ListCopyWith(
              $value.in$!,
              (v, t) => ObjectCopyWith(v, $identity, t),
              (v) => call(in$: v),
            )
          : null;
  @override
  $R call({
    Object? eq = $none,
    Object? ne = $none,
    Object? in$ = $none,
    Object? lt = $none,
    Object? lte = $none,
    Object? gt = $none,
    Object? gte = $none,
    Object? contains = $none,
    Object? startsWith = $none,
    Object? isNull = $none,
  }) =>
      $apply(
        FieldCopyWithData({
          if (eq != $none) #eq: eq,
          if (ne != $none) #ne: ne,
          if (in$ != $none) #in$: in$,
          if (lt != $none) #lt: lt,
          if (lte != $none) #lte: lte,
          if (gt != $none) #gt: gt,
          if (gte != $none) #gte: gte,
          if (contains != $none) #contains: contains,
          if (startsWith != $none) #startsWith: startsWith,
          if (isNull != $none) #isNull: isNull,
        }),
      );
  @override
  StringFilter $make(CopyWithData data) => StringFilter(
        eq: data.get(#eq, or: $value.eq),
        ne: data.get(#ne, or: $value.ne),
        in$: data.get(#in$, or: $value.in$),
        lt: data.get(#lt, or: $value.lt),
        lte: data.get(#lte, or: $value.lte),
        gt: data.get(#gt, or: $value.gt),
        gte: data.get(#gte, or: $value.gte),
        contains: data.get(#contains, or: $value.contains),
        startsWith: data.get(#startsWith, or: $value.startsWith),
        isNull: data.get(#isNull, or: $value.isNull),
      );

  @override
  StringFilterCopyWith<$R2, StringFilter, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _StringFilterCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class NumberFilterMapper extends ClassMapperBase<NumberFilter> {
  NumberFilterMapper._();

  static NumberFilterMapper? _instance;
  static NumberFilterMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = NumberFilterMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'NumberFilter';

  static num? _$eq(NumberFilter v) => v.eq;
  static const Field<NumberFilter, num> _f$eq = Field('eq', _$eq, opt: true);
  static num? _$ne(NumberFilter v) => v.ne;
  static const Field<NumberFilter, num> _f$ne = Field('ne', _$ne, opt: true);
  static List<num>? _$in$(NumberFilter v) => v.in$;
  static const Field<NumberFilter, List<num>> _f$in$ = Field(
    'in\$',
    _$in$,
    opt: true,
  );
  static num? _$lt(NumberFilter v) => v.lt;
  static const Field<NumberFilter, num> _f$lt = Field('lt', _$lt, opt: true);
  static num? _$lte(NumberFilter v) => v.lte;
  static const Field<NumberFilter, num> _f$lte = Field('lte', _$lte, opt: true);
  static num? _$gt(NumberFilter v) => v.gt;
  static const Field<NumberFilter, num> _f$gt = Field('gt', _$gt, opt: true);
  static num? _$gte(NumberFilter v) => v.gte;
  static const Field<NumberFilter, num> _f$gte = Field('gte', _$gte, opt: true);
  static bool? _$isNull(NumberFilter v) => v.isNull;
  static const Field<NumberFilter, bool> _f$isNull = Field(
    'isNull',
    _$isNull,
    opt: true,
  );

  @override
  final MappableFields<NumberFilter> fields = const {
    #eq: _f$eq,
    #ne: _f$ne,
    #in$: _f$in$,
    #lt: _f$lt,
    #lte: _f$lte,
    #gt: _f$gt,
    #gte: _f$gte,
    #isNull: _f$isNull,
  };

  static NumberFilter _instantiate(DecodingData data) {
    return NumberFilter(
      eq: data.dec(_f$eq),
      ne: data.dec(_f$ne),
      in$: data.dec(_f$in$),
      lt: data.dec(_f$lt),
      lte: data.dec(_f$lte),
      gt: data.dec(_f$gt),
      gte: data.dec(_f$gte),
      isNull: data.dec(_f$isNull),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin NumberFilterMappable {
  NumberFilterCopyWith<NumberFilter, NumberFilter, NumberFilter> get copyWith =>
      _NumberFilterCopyWithImpl<NumberFilter, NumberFilter>(
        this as NumberFilter,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return NumberFilterMapper.ensureInitialized().equalsValue(
      this as NumberFilter,
      other,
    );
  }

  @override
  int get hashCode {
    return NumberFilterMapper.ensureInitialized().hashValue(
      this as NumberFilter,
    );
  }
}

extension NumberFilterValueCopy<$R, $Out>
    on ObjectCopyWith<$R, NumberFilter, $Out> {
  NumberFilterCopyWith<$R, NumberFilter, $Out> get $asNumberFilter =>
      $base.as((v, t, t2) => _NumberFilterCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class NumberFilterCopyWith<$R, $In extends NumberFilter, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, num, ObjectCopyWith<$R, num, num>>? get in$;
  $R call({
    num? eq,
    num? ne,
    List<num>? in$,
    num? lt,
    num? lte,
    num? gt,
    num? gte,
    bool? isNull,
  });
  NumberFilterCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _NumberFilterCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, NumberFilter, $Out>
    implements NumberFilterCopyWith<$R, NumberFilter, $Out> {
  _NumberFilterCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<NumberFilter> $mapper =
      NumberFilterMapper.ensureInitialized();
  @override
  ListCopyWith<$R, num, ObjectCopyWith<$R, num, num>>? get in$ =>
      $value.in$ != null
          ? ListCopyWith(
              $value.in$!,
              (v, t) => ObjectCopyWith(v, $identity, t),
              (v) => call(in$: v),
            )
          : null;
  @override
  $R call({
    Object? eq = $none,
    Object? ne = $none,
    Object? in$ = $none,
    Object? lt = $none,
    Object? lte = $none,
    Object? gt = $none,
    Object? gte = $none,
    Object? isNull = $none,
  }) =>
      $apply(
        FieldCopyWithData({
          if (eq != $none) #eq: eq,
          if (ne != $none) #ne: ne,
          if (in$ != $none) #in$: in$,
          if (lt != $none) #lt: lt,
          if (lte != $none) #lte: lte,
          if (gt != $none) #gt: gt,
          if (gte != $none) #gte: gte,
          if (isNull != $none) #isNull: isNull,
        }),
      );
  @override
  NumberFilter $make(CopyWithData data) => NumberFilter(
        eq: data.get(#eq, or: $value.eq),
        ne: data.get(#ne, or: $value.ne),
        in$: data.get(#in$, or: $value.in$),
        lt: data.get(#lt, or: $value.lt),
        lte: data.get(#lte, or: $value.lte),
        gt: data.get(#gt, or: $value.gt),
        gte: data.get(#gte, or: $value.gte),
        isNull: data.get(#isNull, or: $value.isNull),
      );

  @override
  NumberFilterCopyWith<$R2, NumberFilter, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _NumberFilterCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class BigIntFilterMapper extends ClassMapperBase<BigIntFilter> {
  BigIntFilterMapper._();

  static BigIntFilterMapper? _instance;
  static BigIntFilterMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = BigIntFilterMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'BigIntFilter';

  static BigInt? _$eq(BigIntFilter v) => v.eq;
  static const Field<BigIntFilter, BigInt> _f$eq = Field('eq', _$eq, opt: true);
  static BigInt? _$ne(BigIntFilter v) => v.ne;
  static const Field<BigIntFilter, BigInt> _f$ne = Field('ne', _$ne, opt: true);
  static List<BigInt>? _$in$(BigIntFilter v) => v.in$;
  static const Field<BigIntFilter, List<BigInt>> _f$in$ = Field(
    'in\$',
    _$in$,
    opt: true,
  );
  static BigInt? _$lt(BigIntFilter v) => v.lt;
  static const Field<BigIntFilter, BigInt> _f$lt = Field('lt', _$lt, opt: true);
  static BigInt? _$lte(BigIntFilter v) => v.lte;
  static const Field<BigIntFilter, BigInt> _f$lte = Field(
    'lte',
    _$lte,
    opt: true,
  );
  static BigInt? _$gt(BigIntFilter v) => v.gt;
  static const Field<BigIntFilter, BigInt> _f$gt = Field('gt', _$gt, opt: true);
  static BigInt? _$gte(BigIntFilter v) => v.gte;
  static const Field<BigIntFilter, BigInt> _f$gte = Field(
    'gte',
    _$gte,
    opt: true,
  );
  static bool? _$isNull(BigIntFilter v) => v.isNull;
  static const Field<BigIntFilter, bool> _f$isNull = Field(
    'isNull',
    _$isNull,
    opt: true,
  );

  @override
  final MappableFields<BigIntFilter> fields = const {
    #eq: _f$eq,
    #ne: _f$ne,
    #in$: _f$in$,
    #lt: _f$lt,
    #lte: _f$lte,
    #gt: _f$gt,
    #gte: _f$gte,
    #isNull: _f$isNull,
  };

  static BigIntFilter _instantiate(DecodingData data) {
    return BigIntFilter(
      eq: data.dec(_f$eq),
      ne: data.dec(_f$ne),
      in$: data.dec(_f$in$),
      lt: data.dec(_f$lt),
      lte: data.dec(_f$lte),
      gt: data.dec(_f$gt),
      gte: data.dec(_f$gte),
      isNull: data.dec(_f$isNull),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin BigIntFilterMappable {
  BigIntFilterCopyWith<BigIntFilter, BigIntFilter, BigIntFilter> get copyWith =>
      _BigIntFilterCopyWithImpl<BigIntFilter, BigIntFilter>(
        this as BigIntFilter,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return BigIntFilterMapper.ensureInitialized().equalsValue(
      this as BigIntFilter,
      other,
    );
  }

  @override
  int get hashCode {
    return BigIntFilterMapper.ensureInitialized().hashValue(
      this as BigIntFilter,
    );
  }
}

extension BigIntFilterValueCopy<$R, $Out>
    on ObjectCopyWith<$R, BigIntFilter, $Out> {
  BigIntFilterCopyWith<$R, BigIntFilter, $Out> get $asBigIntFilter =>
      $base.as((v, t, t2) => _BigIntFilterCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class BigIntFilterCopyWith<$R, $In extends BigIntFilter, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, BigInt, ObjectCopyWith<$R, BigInt, BigInt>>? get in$;
  $R call({
    BigInt? eq,
    BigInt? ne,
    List<BigInt>? in$,
    BigInt? lt,
    BigInt? lte,
    BigInt? gt,
    BigInt? gte,
    bool? isNull,
  });
  BigIntFilterCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _BigIntFilterCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, BigIntFilter, $Out>
    implements BigIntFilterCopyWith<$R, BigIntFilter, $Out> {
  _BigIntFilterCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<BigIntFilter> $mapper =
      BigIntFilterMapper.ensureInitialized();
  @override
  ListCopyWith<$R, BigInt, ObjectCopyWith<$R, BigInt, BigInt>>? get in$ =>
      $value.in$ != null
          ? ListCopyWith(
              $value.in$!,
              (v, t) => ObjectCopyWith(v, $identity, t),
              (v) => call(in$: v),
            )
          : null;
  @override
  $R call({
    Object? eq = $none,
    Object? ne = $none,
    Object? in$ = $none,
    Object? lt = $none,
    Object? lte = $none,
    Object? gt = $none,
    Object? gte = $none,
    Object? isNull = $none,
  }) =>
      $apply(
        FieldCopyWithData({
          if (eq != $none) #eq: eq,
          if (ne != $none) #ne: ne,
          if (in$ != $none) #in$: in$,
          if (lt != $none) #lt: lt,
          if (lte != $none) #lte: lte,
          if (gt != $none) #gt: gt,
          if (gte != $none) #gte: gte,
          if (isNull != $none) #isNull: isNull,
        }),
      );
  @override
  BigIntFilter $make(CopyWithData data) => BigIntFilter(
        eq: data.get(#eq, or: $value.eq),
        ne: data.get(#ne, or: $value.ne),
        in$: data.get(#in$, or: $value.in$),
        lt: data.get(#lt, or: $value.lt),
        lte: data.get(#lte, or: $value.lte),
        gt: data.get(#gt, or: $value.gt),
        gte: data.get(#gte, or: $value.gte),
        isNull: data.get(#isNull, or: $value.isNull),
      );

  @override
  BigIntFilterCopyWith<$R2, BigIntFilter, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _BigIntFilterCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class BooleanFilterMapper extends ClassMapperBase<BooleanFilter> {
  BooleanFilterMapper._();

  static BooleanFilterMapper? _instance;
  static BooleanFilterMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = BooleanFilterMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'BooleanFilter';

  static bool? _$eq(BooleanFilter v) => v.eq;
  static const Field<BooleanFilter, bool> _f$eq = Field('eq', _$eq, opt: true);
  static bool? _$ne(BooleanFilter v) => v.ne;
  static const Field<BooleanFilter, bool> _f$ne = Field('ne', _$ne, opt: true);
  static List<bool>? _$in$(BooleanFilter v) => v.in$;
  static const Field<BooleanFilter, List<bool>> _f$in$ = Field(
    'in\$',
    _$in$,
    opt: true,
  );
  static bool? _$isNull(BooleanFilter v) => v.isNull;
  static const Field<BooleanFilter, bool> _f$isNull = Field(
    'isNull',
    _$isNull,
    opt: true,
  );

  @override
  final MappableFields<BooleanFilter> fields = const {
    #eq: _f$eq,
    #ne: _f$ne,
    #in$: _f$in$,
    #isNull: _f$isNull,
  };

  static BooleanFilter _instantiate(DecodingData data) {
    return BooleanFilter(
      eq: data.dec(_f$eq),
      ne: data.dec(_f$ne),
      in$: data.dec(_f$in$),
      isNull: data.dec(_f$isNull),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin BooleanFilterMappable {
  BooleanFilterCopyWith<BooleanFilter, BooleanFilter, BooleanFilter>
      get copyWith => _BooleanFilterCopyWithImpl<BooleanFilter, BooleanFilter>(
            this as BooleanFilter,
            $identity,
            $identity,
          );
  @override
  bool operator ==(Object other) {
    return BooleanFilterMapper.ensureInitialized().equalsValue(
      this as BooleanFilter,
      other,
    );
  }

  @override
  int get hashCode {
    return BooleanFilterMapper.ensureInitialized().hashValue(
      this as BooleanFilter,
    );
  }
}

extension BooleanFilterValueCopy<$R, $Out>
    on ObjectCopyWith<$R, BooleanFilter, $Out> {
  BooleanFilterCopyWith<$R, BooleanFilter, $Out> get $asBooleanFilter =>
      $base.as((v, t, t2) => _BooleanFilterCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class BooleanFilterCopyWith<$R, $In extends BooleanFilter, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, bool, ObjectCopyWith<$R, bool, bool>>? get in$;
  $R call({bool? eq, bool? ne, List<bool>? in$, bool? isNull});
  BooleanFilterCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _BooleanFilterCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, BooleanFilter, $Out>
    implements BooleanFilterCopyWith<$R, BooleanFilter, $Out> {
  _BooleanFilterCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<BooleanFilter> $mapper =
      BooleanFilterMapper.ensureInitialized();
  @override
  ListCopyWith<$R, bool, ObjectCopyWith<$R, bool, bool>>? get in$ =>
      $value.in$ != null
          ? ListCopyWith(
              $value.in$!,
              (v, t) => ObjectCopyWith(v, $identity, t),
              (v) => call(in$: v),
            )
          : null;
  @override
  $R call({
    Object? eq = $none,
    Object? ne = $none,
    Object? in$ = $none,
    Object? isNull = $none,
  }) =>
      $apply(
        FieldCopyWithData({
          if (eq != $none) #eq: eq,
          if (ne != $none) #ne: ne,
          if (in$ != $none) #in$: in$,
          if (isNull != $none) #isNull: isNull,
        }),
      );
  @override
  BooleanFilter $make(CopyWithData data) => BooleanFilter(
        eq: data.get(#eq, or: $value.eq),
        ne: data.get(#ne, or: $value.ne),
        in$: data.get(#in$, or: $value.in$),
        isNull: data.get(#isNull, or: $value.isNull),
      );

  @override
  BooleanFilterCopyWith<$R2, BooleanFilter, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _BooleanFilterCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class UuidFilterMapper extends ClassMapperBase<UuidFilter> {
  UuidFilterMapper._();

  static UuidFilterMapper? _instance;
  static UuidFilterMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = UuidFilterMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'UuidFilter';

  static String? _$eq(UuidFilter v) => v.eq;
  static const Field<UuidFilter, String> _f$eq = Field('eq', _$eq, opt: true);
  static String? _$ne(UuidFilter v) => v.ne;
  static const Field<UuidFilter, String> _f$ne = Field('ne', _$ne, opt: true);
  static List<String>? _$in$(UuidFilter v) => v.in$;
  static const Field<UuidFilter, List<String>> _f$in$ = Field(
    'in\$',
    _$in$,
    opt: true,
  );
  static String? _$lt(UuidFilter v) => v.lt;
  static const Field<UuidFilter, String> _f$lt = Field('lt', _$lt, opt: true);
  static String? _$lte(UuidFilter v) => v.lte;
  static const Field<UuidFilter, String> _f$lte = Field(
    'lte',
    _$lte,
    opt: true,
  );
  static String? _$gt(UuidFilter v) => v.gt;
  static const Field<UuidFilter, String> _f$gt = Field('gt', _$gt, opt: true);
  static String? _$gte(UuidFilter v) => v.gte;
  static const Field<UuidFilter, String> _f$gte = Field(
    'gte',
    _$gte,
    opt: true,
  );
  static bool? _$isNull(UuidFilter v) => v.isNull;
  static const Field<UuidFilter, bool> _f$isNull = Field(
    'isNull',
    _$isNull,
    opt: true,
  );

  @override
  final MappableFields<UuidFilter> fields = const {
    #eq: _f$eq,
    #ne: _f$ne,
    #in$: _f$in$,
    #lt: _f$lt,
    #lte: _f$lte,
    #gt: _f$gt,
    #gte: _f$gte,
    #isNull: _f$isNull,
  };

  static UuidFilter _instantiate(DecodingData data) {
    return UuidFilter(
      eq: data.dec(_f$eq),
      ne: data.dec(_f$ne),
      in$: data.dec(_f$in$),
      lt: data.dec(_f$lt),
      lte: data.dec(_f$lte),
      gt: data.dec(_f$gt),
      gte: data.dec(_f$gte),
      isNull: data.dec(_f$isNull),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin UuidFilterMappable {
  UuidFilterCopyWith<UuidFilter, UuidFilter, UuidFilter> get copyWith =>
      _UuidFilterCopyWithImpl<UuidFilter, UuidFilter>(
        this as UuidFilter,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return UuidFilterMapper.ensureInitialized().equalsValue(
      this as UuidFilter,
      other,
    );
  }

  @override
  int get hashCode {
    return UuidFilterMapper.ensureInitialized().hashValue(this as UuidFilter);
  }
}

extension UuidFilterValueCopy<$R, $Out>
    on ObjectCopyWith<$R, UuidFilter, $Out> {
  UuidFilterCopyWith<$R, UuidFilter, $Out> get $asUuidFilter =>
      $base.as((v, t, t2) => _UuidFilterCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class UuidFilterCopyWith<$R, $In extends UuidFilter, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, String, ObjectCopyWith<$R, String, String>>? get in$;
  $R call({
    String? eq,
    String? ne,
    List<String>? in$,
    String? lt,
    String? lte,
    String? gt,
    String? gte,
    bool? isNull,
  });
  UuidFilterCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _UuidFilterCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, UuidFilter, $Out>
    implements UuidFilterCopyWith<$R, UuidFilter, $Out> {
  _UuidFilterCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<UuidFilter> $mapper =
      UuidFilterMapper.ensureInitialized();
  @override
  ListCopyWith<$R, String, ObjectCopyWith<$R, String, String>>? get in$ =>
      $value.in$ != null
          ? ListCopyWith(
              $value.in$!,
              (v, t) => ObjectCopyWith(v, $identity, t),
              (v) => call(in$: v),
            )
          : null;
  @override
  $R call({
    Object? eq = $none,
    Object? ne = $none,
    Object? in$ = $none,
    Object? lt = $none,
    Object? lte = $none,
    Object? gt = $none,
    Object? gte = $none,
    Object? isNull = $none,
  }) =>
      $apply(
        FieldCopyWithData({
          if (eq != $none) #eq: eq,
          if (ne != $none) #ne: ne,
          if (in$ != $none) #in$: in$,
          if (lt != $none) #lt: lt,
          if (lte != $none) #lte: lte,
          if (gt != $none) #gt: gt,
          if (gte != $none) #gte: gte,
          if (isNull != $none) #isNull: isNull,
        }),
      );
  @override
  UuidFilter $make(CopyWithData data) => UuidFilter(
        eq: data.get(#eq, or: $value.eq),
        ne: data.get(#ne, or: $value.ne),
        in$: data.get(#in$, or: $value.in$),
        lt: data.get(#lt, or: $value.lt),
        lte: data.get(#lte, or: $value.lte),
        gt: data.get(#gt, or: $value.gt),
        gte: data.get(#gte, or: $value.gte),
        isNull: data.get(#isNull, or: $value.isNull),
      );

  @override
  UuidFilterCopyWith<$R2, UuidFilter, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _UuidFilterCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class DateTimeFilterMapper extends ClassMapperBase<DateTimeFilter> {
  DateTimeFilterMapper._();

  static DateTimeFilterMapper? _instance;
  static DateTimeFilterMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = DateTimeFilterMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'DateTimeFilter';

  static DateTime? _$eq(DateTimeFilter v) => v.eq;
  static const Field<DateTimeFilter, DateTime> _f$eq = Field(
    'eq',
    _$eq,
    opt: true,
  );
  static DateTime? _$ne(DateTimeFilter v) => v.ne;
  static const Field<DateTimeFilter, DateTime> _f$ne = Field(
    'ne',
    _$ne,
    opt: true,
  );
  static List<DateTime>? _$in$(DateTimeFilter v) => v.in$;
  static const Field<DateTimeFilter, List<DateTime>> _f$in$ = Field(
    'in\$',
    _$in$,
    opt: true,
  );
  static DateTime? _$lt(DateTimeFilter v) => v.lt;
  static const Field<DateTimeFilter, DateTime> _f$lt = Field(
    'lt',
    _$lt,
    opt: true,
  );
  static DateTime? _$lte(DateTimeFilter v) => v.lte;
  static const Field<DateTimeFilter, DateTime> _f$lte = Field(
    'lte',
    _$lte,
    opt: true,
  );
  static DateTime? _$gt(DateTimeFilter v) => v.gt;
  static const Field<DateTimeFilter, DateTime> _f$gt = Field(
    'gt',
    _$gt,
    opt: true,
  );
  static DateTime? _$gte(DateTimeFilter v) => v.gte;
  static const Field<DateTimeFilter, DateTime> _f$gte = Field(
    'gte',
    _$gte,
    opt: true,
  );
  static bool? _$isNull(DateTimeFilter v) => v.isNull;
  static const Field<DateTimeFilter, bool> _f$isNull = Field(
    'isNull',
    _$isNull,
    opt: true,
  );

  @override
  final MappableFields<DateTimeFilter> fields = const {
    #eq: _f$eq,
    #ne: _f$ne,
    #in$: _f$in$,
    #lt: _f$lt,
    #lte: _f$lte,
    #gt: _f$gt,
    #gte: _f$gte,
    #isNull: _f$isNull,
  };

  static DateTimeFilter _instantiate(DecodingData data) {
    return DateTimeFilter(
      eq: data.dec(_f$eq),
      ne: data.dec(_f$ne),
      in$: data.dec(_f$in$),
      lt: data.dec(_f$lt),
      lte: data.dec(_f$lte),
      gt: data.dec(_f$gt),
      gte: data.dec(_f$gte),
      isNull: data.dec(_f$isNull),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin DateTimeFilterMappable {
  DateTimeFilterCopyWith<DateTimeFilter, DateTimeFilter, DateTimeFilter>
      get copyWith =>
          _DateTimeFilterCopyWithImpl<DateTimeFilter, DateTimeFilter>(
            this as DateTimeFilter,
            $identity,
            $identity,
          );
  @override
  bool operator ==(Object other) {
    return DateTimeFilterMapper.ensureInitialized().equalsValue(
      this as DateTimeFilter,
      other,
    );
  }

  @override
  int get hashCode {
    return DateTimeFilterMapper.ensureInitialized().hashValue(
      this as DateTimeFilter,
    );
  }
}

extension DateTimeFilterValueCopy<$R, $Out>
    on ObjectCopyWith<$R, DateTimeFilter, $Out> {
  DateTimeFilterCopyWith<$R, DateTimeFilter, $Out> get $asDateTimeFilter =>
      $base.as((v, t, t2) => _DateTimeFilterCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class DateTimeFilterCopyWith<$R, $In extends DateTimeFilter, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, DateTime, ObjectCopyWith<$R, DateTime, DateTime>>? get in$;
  $R call({
    DateTime? eq,
    DateTime? ne,
    List<DateTime>? in$,
    DateTime? lt,
    DateTime? lte,
    DateTime? gt,
    DateTime? gte,
    bool? isNull,
  });
  DateTimeFilterCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _DateTimeFilterCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, DateTimeFilter, $Out>
    implements DateTimeFilterCopyWith<$R, DateTimeFilter, $Out> {
  _DateTimeFilterCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<DateTimeFilter> $mapper =
      DateTimeFilterMapper.ensureInitialized();
  @override
  ListCopyWith<$R, DateTime, ObjectCopyWith<$R, DateTime, DateTime>>? get in$ =>
      $value.in$ != null
          ? ListCopyWith(
              $value.in$!,
              (v, t) => ObjectCopyWith(v, $identity, t),
              (v) => call(in$: v),
            )
          : null;
  @override
  $R call({
    Object? eq = $none,
    Object? ne = $none,
    Object? in$ = $none,
    Object? lt = $none,
    Object? lte = $none,
    Object? gt = $none,
    Object? gte = $none,
    Object? isNull = $none,
  }) =>
      $apply(
        FieldCopyWithData({
          if (eq != $none) #eq: eq,
          if (ne != $none) #ne: ne,
          if (in$ != $none) #in$: in$,
          if (lt != $none) #lt: lt,
          if (lte != $none) #lte: lte,
          if (gt != $none) #gt: gt,
          if (gte != $none) #gte: gte,
          if (isNull != $none) #isNull: isNull,
        }),
      );
  @override
  DateTimeFilter $make(CopyWithData data) => DateTimeFilter(
        eq: data.get(#eq, or: $value.eq),
        ne: data.get(#ne, or: $value.ne),
        in$: data.get(#in$, or: $value.in$),
        lt: data.get(#lt, or: $value.lt),
        lte: data.get(#lte, or: $value.lte),
        gt: data.get(#gt, or: $value.gt),
        gte: data.get(#gte, or: $value.gte),
        isNull: data.get(#isNull, or: $value.isNull),
      );

  @override
  DateTimeFilterCopyWith<$R2, DateTimeFilter, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _DateTimeFilterCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class DecimalFilterMapper extends ClassMapperBase<DecimalFilter> {
  DecimalFilterMapper._();

  static DecimalFilterMapper? _instance;
  static DecimalFilterMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = DecimalFilterMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'DecimalFilter';

  static Decimal? _$eq(DecimalFilter v) => v.eq;
  static const Field<DecimalFilter, Decimal> _f$eq = Field(
    'eq',
    _$eq,
    opt: true,
  );
  static Decimal? _$ne(DecimalFilter v) => v.ne;
  static const Field<DecimalFilter, Decimal> _f$ne = Field(
    'ne',
    _$ne,
    opt: true,
  );
  static List<Decimal>? _$in$(DecimalFilter v) => v.in$;
  static const Field<DecimalFilter, List<Decimal>> _f$in$ = Field(
    'in\$',
    _$in$,
    opt: true,
  );
  static Decimal? _$lt(DecimalFilter v) => v.lt;
  static const Field<DecimalFilter, Decimal> _f$lt = Field(
    'lt',
    _$lt,
    opt: true,
  );
  static Decimal? _$lte(DecimalFilter v) => v.lte;
  static const Field<DecimalFilter, Decimal> _f$lte = Field(
    'lte',
    _$lte,
    opt: true,
  );
  static Decimal? _$gt(DecimalFilter v) => v.gt;
  static const Field<DecimalFilter, Decimal> _f$gt = Field(
    'gt',
    _$gt,
    opt: true,
  );
  static Decimal? _$gte(DecimalFilter v) => v.gte;
  static const Field<DecimalFilter, Decimal> _f$gte = Field(
    'gte',
    _$gte,
    opt: true,
  );
  static bool? _$isNull(DecimalFilter v) => v.isNull;
  static const Field<DecimalFilter, bool> _f$isNull = Field(
    'isNull',
    _$isNull,
    opt: true,
  );

  @override
  final MappableFields<DecimalFilter> fields = const {
    #eq: _f$eq,
    #ne: _f$ne,
    #in$: _f$in$,
    #lt: _f$lt,
    #lte: _f$lte,
    #gt: _f$gt,
    #gte: _f$gte,
    #isNull: _f$isNull,
  };

  static DecimalFilter _instantiate(DecodingData data) {
    return DecimalFilter(
      eq: data.dec(_f$eq),
      ne: data.dec(_f$ne),
      in$: data.dec(_f$in$),
      lt: data.dec(_f$lt),
      lte: data.dec(_f$lte),
      gt: data.dec(_f$gt),
      gte: data.dec(_f$gte),
      isNull: data.dec(_f$isNull),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin DecimalFilterMappable {
  DecimalFilterCopyWith<DecimalFilter, DecimalFilter, DecimalFilter>
      get copyWith => _DecimalFilterCopyWithImpl<DecimalFilter, DecimalFilter>(
            this as DecimalFilter,
            $identity,
            $identity,
          );
  @override
  bool operator ==(Object other) {
    return DecimalFilterMapper.ensureInitialized().equalsValue(
      this as DecimalFilter,
      other,
    );
  }

  @override
  int get hashCode {
    return DecimalFilterMapper.ensureInitialized().hashValue(
      this as DecimalFilter,
    );
  }
}

extension DecimalFilterValueCopy<$R, $Out>
    on ObjectCopyWith<$R, DecimalFilter, $Out> {
  DecimalFilterCopyWith<$R, DecimalFilter, $Out> get $asDecimalFilter =>
      $base.as((v, t, t2) => _DecimalFilterCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class DecimalFilterCopyWith<$R, $In extends DecimalFilter, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, Decimal, ObjectCopyWith<$R, Decimal, Decimal>>? get in$;
  $R call({
    Decimal? eq,
    Decimal? ne,
    List<Decimal>? in$,
    Decimal? lt,
    Decimal? lte,
    Decimal? gt,
    Decimal? gte,
    bool? isNull,
  });
  DecimalFilterCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _DecimalFilterCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, DecimalFilter, $Out>
    implements DecimalFilterCopyWith<$R, DecimalFilter, $Out> {
  _DecimalFilterCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<DecimalFilter> $mapper =
      DecimalFilterMapper.ensureInitialized();
  @override
  ListCopyWith<$R, Decimal, ObjectCopyWith<$R, Decimal, Decimal>>? get in$ =>
      $value.in$ != null
          ? ListCopyWith(
              $value.in$!,
              (v, t) => ObjectCopyWith(v, $identity, t),
              (v) => call(in$: v),
            )
          : null;
  @override
  $R call({
    Object? eq = $none,
    Object? ne = $none,
    Object? in$ = $none,
    Object? lt = $none,
    Object? lte = $none,
    Object? gt = $none,
    Object? gte = $none,
    Object? isNull = $none,
  }) =>
      $apply(
        FieldCopyWithData({
          if (eq != $none) #eq: eq,
          if (ne != $none) #ne: ne,
          if (in$ != $none) #in$: in$,
          if (lt != $none) #lt: lt,
          if (lte != $none) #lte: lte,
          if (gt != $none) #gt: gt,
          if (gte != $none) #gte: gte,
          if (isNull != $none) #isNull: isNull,
        }),
      );
  @override
  DecimalFilter $make(CopyWithData data) => DecimalFilter(
        eq: data.get(#eq, or: $value.eq),
        ne: data.get(#ne, or: $value.ne),
        in$: data.get(#in$, or: $value.in$),
        lt: data.get(#lt, or: $value.lt),
        lte: data.get(#lte, or: $value.lte),
        gt: data.get(#gt, or: $value.gt),
        gte: data.get(#gte, or: $value.gte),
        isNull: data.get(#isNull, or: $value.isNull),
      );

  @override
  DecimalFilterCopyWith<$R2, DecimalFilter, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _DecimalFilterCopyWithImpl<$R2, $Out2>($value, $cast, t);
}
