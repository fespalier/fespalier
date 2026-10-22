// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'procedures.dart';

class BeginEnrolmentProcedureArgsMapper
    extends ClassMapperBase<BeginEnrolmentProcedureArgs> {
  BeginEnrolmentProcedureArgsMapper._();

  static BeginEnrolmentProcedureArgsMapper? _instance;
  static BeginEnrolmentProcedureArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = BeginEnrolmentProcedureArgsMapper._(),
      );
      BeginEnrolmentArgsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'BeginEnrolmentProcedureArgs';

  static BeginEnrolmentArgs _$args(BeginEnrolmentProcedureArgs v) => v.args;
  static const Field<BeginEnrolmentProcedureArgs, BeginEnrolmentArgs> _f$args =
      Field('args', _$args);

  @override
  final MappableFields<BeginEnrolmentProcedureArgs> fields = const {
    #args: _f$args,
  };

  static BeginEnrolmentProcedureArgs _instantiate(DecodingData data) {
    return BeginEnrolmentProcedureArgs(args: data.dec(_f$args));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin BeginEnrolmentProcedureArgsMappable {
  BeginEnrolmentProcedureArgsCopyWith<BeginEnrolmentProcedureArgs,
          BeginEnrolmentProcedureArgs, BeginEnrolmentProcedureArgs>
      get copyWith => _BeginEnrolmentProcedureArgsCopyWithImpl<
              BeginEnrolmentProcedureArgs, BeginEnrolmentProcedureArgs>(
          this as BeginEnrolmentProcedureArgs, $identity, $identity);
  @override
  bool operator ==(Object other) {
    return BeginEnrolmentProcedureArgsMapper.ensureInitialized().equalsValue(
      this as BeginEnrolmentProcedureArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return BeginEnrolmentProcedureArgsMapper.ensureInitialized().hashValue(
      this as BeginEnrolmentProcedureArgs,
    );
  }
}

extension BeginEnrolmentProcedureArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, BeginEnrolmentProcedureArgs, $Out> {
  BeginEnrolmentProcedureArgsCopyWith<$R, BeginEnrolmentProcedureArgs, $Out>
      get $asBeginEnrolmentProcedureArgs => $base.as(
            (v, t, t2) =>
                _BeginEnrolmentProcedureArgsCopyWithImpl<$R, $Out>(v, t, t2),
          );
}

abstract class BeginEnrolmentProcedureArgsCopyWith<
    $R,
    $In extends BeginEnrolmentProcedureArgs,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  BeginEnrolmentArgsCopyWith<$R, BeginEnrolmentArgs, BeginEnrolmentArgs>
      get args;
  $R call({BeginEnrolmentArgs? args});
  BeginEnrolmentProcedureArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _BeginEnrolmentProcedureArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, BeginEnrolmentProcedureArgs, $Out>
    implements
        BeginEnrolmentProcedureArgsCopyWith<$R, BeginEnrolmentProcedureArgs,
            $Out> {
  _BeginEnrolmentProcedureArgsCopyWithImpl(
    super.value,
    super.then,
    super.then2,
  );

  @override
  late final ClassMapperBase<BeginEnrolmentProcedureArgs> $mapper =
      BeginEnrolmentProcedureArgsMapper.ensureInitialized();
  @override
  BeginEnrolmentArgsCopyWith<$R, BeginEnrolmentArgs, BeginEnrolmentArgs>
      get args => $value.args.copyWith.$chain((v) => call(args: v));
  @override
  $R call({BeginEnrolmentArgs? args}) =>
      $apply(FieldCopyWithData({if (args != null) #args: args}));
  @override
  BeginEnrolmentProcedureArgs $make(CopyWithData data) =>
      BeginEnrolmentProcedureArgs(args: data.get(#args, or: $value.args));

  @override
  BeginEnrolmentProcedureArgsCopyWith<$R2, BeginEnrolmentProcedureArgs, $Out2>
      $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
          _BeginEnrolmentProcedureArgsCopyWithImpl<$R2, $Out2>(
              $value, $cast, t);
}

class BeginEnrolmentArgsMapper extends ClassMapperBase<BeginEnrolmentArgs> {
  BeginEnrolmentArgsMapper._();

  static BeginEnrolmentArgsMapper? _instance;
  static BeginEnrolmentArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = BeginEnrolmentArgsMapper._());
      JwkMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'BeginEnrolmentArgs';

  static String _$phone(BeginEnrolmentArgs v) => v.phone;
  static const Field<BeginEnrolmentArgs, String> _f$phone = Field(
    'phone',
    _$phone,
  );
  static Jwk _$ambient(BeginEnrolmentArgs v) => v.ambient;
  static const Field<BeginEnrolmentArgs, Jwk> _f$ambient = Field(
    'ambient',
    _$ambient,
  );
  static Jwk? _$userPresent(BeginEnrolmentArgs v) => v.userPresent;
  static const Field<BeginEnrolmentArgs, Jwk> _f$userPresent = Field(
    'userPresent',
    _$userPresent,
    opt: true,
  );

  @override
  final MappableFields<BeginEnrolmentArgs> fields = const {
    #phone: _f$phone,
    #ambient: _f$ambient,
    #userPresent: _f$userPresent,
  };

  static BeginEnrolmentArgs _instantiate(DecodingData data) {
    return BeginEnrolmentArgs(
      phone: data.dec(_f$phone),
      ambient: data.dec(_f$ambient),
      userPresent: data.dec(_f$userPresent),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin BeginEnrolmentArgsMappable {
  BeginEnrolmentArgsCopyWith<BeginEnrolmentArgs, BeginEnrolmentArgs,
      BeginEnrolmentArgs> get copyWith => _BeginEnrolmentArgsCopyWithImpl<
          BeginEnrolmentArgs, BeginEnrolmentArgs>(
        this as BeginEnrolmentArgs,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return BeginEnrolmentArgsMapper.ensureInitialized().equalsValue(
      this as BeginEnrolmentArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return BeginEnrolmentArgsMapper.ensureInitialized().hashValue(
      this as BeginEnrolmentArgs,
    );
  }
}

extension BeginEnrolmentArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, BeginEnrolmentArgs, $Out> {
  BeginEnrolmentArgsCopyWith<$R, BeginEnrolmentArgs, $Out>
      get $asBeginEnrolmentArgs => $base.as(
            (v, t, t2) => _BeginEnrolmentArgsCopyWithImpl<$R, $Out>(v, t, t2),
          );
}

abstract class BeginEnrolmentArgsCopyWith<$R, $In extends BeginEnrolmentArgs,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  JwkCopyWith<$R, Jwk, Jwk> get ambient;
  JwkCopyWith<$R, Jwk, Jwk>? get userPresent;
  $R call({String? phone, Jwk? ambient, Jwk? userPresent});
  BeginEnrolmentArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _BeginEnrolmentArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, BeginEnrolmentArgs, $Out>
    implements BeginEnrolmentArgsCopyWith<$R, BeginEnrolmentArgs, $Out> {
  _BeginEnrolmentArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<BeginEnrolmentArgs> $mapper =
      BeginEnrolmentArgsMapper.ensureInitialized();
  @override
  JwkCopyWith<$R, Jwk, Jwk> get ambient =>
      $value.ambient.copyWith.$chain((v) => call(ambient: v));
  @override
  JwkCopyWith<$R, Jwk, Jwk>? get userPresent =>
      $value.userPresent?.copyWith.$chain((v) => call(userPresent: v));
  @override
  $R call({String? phone, Jwk? ambient, Object? userPresent = $none}) => $apply(
        FieldCopyWithData({
          if (phone != null) #phone: phone,
          if (ambient != null) #ambient: ambient,
          if (userPresent != $none) #userPresent: userPresent,
        }),
      );
  @override
  BeginEnrolmentArgs $make(CopyWithData data) => BeginEnrolmentArgs(
        phone: data.get(#phone, or: $value.phone),
        ambient: data.get(#ambient, or: $value.ambient),
        userPresent: data.get(#userPresent, or: $value.userPresent),
      );

  @override
  BeginEnrolmentArgsCopyWith<$R2, BeginEnrolmentArgs, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _BeginEnrolmentArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class JwkMapper extends ClassMapperBase<Jwk> {
  JwkMapper._();

  static JwkMapper? _instance;
  static JwkMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = JwkMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Jwk';

  static String _$kty(Jwk v) => v.kty;
  static const Field<Jwk, String> _f$kty = Field('kty', _$kty);
  static String _$crv(Jwk v) => v.crv;
  static const Field<Jwk, String> _f$crv = Field('crv', _$crv);
  static String _$x(Jwk v) => v.x;
  static const Field<Jwk, String> _f$x = Field('x', _$x);
  static String _$y(Jwk v) => v.y;
  static const Field<Jwk, String> _f$y = Field('y', _$y);

  @override
  final MappableFields<Jwk> fields = const {
    #kty: _f$kty,
    #crv: _f$crv,
    #x: _f$x,
    #y: _f$y,
  };

  static Jwk _instantiate(DecodingData data) {
    return Jwk(
      kty: data.dec(_f$kty),
      crv: data.dec(_f$crv),
      x: data.dec(_f$x),
      y: data.dec(_f$y),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin JwkMappable {
  JwkCopyWith<Jwk, Jwk, Jwk> get copyWith =>
      _JwkCopyWithImpl<Jwk, Jwk>(this as Jwk, $identity, $identity);
  @override
  bool operator ==(Object other) {
    return JwkMapper.ensureInitialized().equalsValue(this as Jwk, other);
  }

  @override
  int get hashCode {
    return JwkMapper.ensureInitialized().hashValue(this as Jwk);
  }
}

extension JwkValueCopy<$R, $Out> on ObjectCopyWith<$R, Jwk, $Out> {
  JwkCopyWith<$R, Jwk, $Out> get $asJwk =>
      $base.as((v, t, t2) => _JwkCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class JwkCopyWith<$R, $In extends Jwk, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({String? kty, String? crv, String? x, String? y});
  JwkCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _JwkCopyWithImpl<$R, $Out> extends ClassCopyWithBase<$R, Jwk, $Out>
    implements JwkCopyWith<$R, Jwk, $Out> {
  _JwkCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<Jwk> $mapper = JwkMapper.ensureInitialized();
  @override
  $R call({String? kty, String? crv, String? x, String? y}) => $apply(
        FieldCopyWithData({
          if (kty != null) #kty: kty,
          if (crv != null) #crv: crv,
          if (x != null) #x: x,
          if (y != null) #y: y,
        }),
      );
  @override
  Jwk $make(CopyWithData data) => Jwk(
        kty: data.get(#kty, or: $value.kty),
        crv: data.get(#crv, or: $value.crv),
        x: data.get(#x, or: $value.x),
        y: data.get(#y, or: $value.y),
      );

  @override
  JwkCopyWith<$R2, Jwk, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _JwkCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class ConfirmEnrolmentProcedureArgsMapper
    extends ClassMapperBase<ConfirmEnrolmentProcedureArgs> {
  ConfirmEnrolmentProcedureArgsMapper._();

  static ConfirmEnrolmentProcedureArgsMapper? _instance;
  static ConfirmEnrolmentProcedureArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = ConfirmEnrolmentProcedureArgsMapper._(),
      );
      ConfirmEnrolmentArgsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'ConfirmEnrolmentProcedureArgs';

  static ConfirmEnrolmentArgs _$args(ConfirmEnrolmentProcedureArgs v) => v.args;
  static const Field<ConfirmEnrolmentProcedureArgs, ConfirmEnrolmentArgs>
      _f$args = Field('args', _$args);

  @override
  final MappableFields<ConfirmEnrolmentProcedureArgs> fields = const {
    #args: _f$args,
  };

  static ConfirmEnrolmentProcedureArgs _instantiate(DecodingData data) {
    return ConfirmEnrolmentProcedureArgs(args: data.dec(_f$args));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin ConfirmEnrolmentProcedureArgsMappable {
  ConfirmEnrolmentProcedureArgsCopyWith<ConfirmEnrolmentProcedureArgs,
          ConfirmEnrolmentProcedureArgs, ConfirmEnrolmentProcedureArgs>
      get copyWith => _ConfirmEnrolmentProcedureArgsCopyWithImpl<
              ConfirmEnrolmentProcedureArgs, ConfirmEnrolmentProcedureArgs>(
          this as ConfirmEnrolmentProcedureArgs, $identity, $identity);
  @override
  bool operator ==(Object other) {
    return ConfirmEnrolmentProcedureArgsMapper.ensureInitialized().equalsValue(
      this as ConfirmEnrolmentProcedureArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return ConfirmEnrolmentProcedureArgsMapper.ensureInitialized().hashValue(
      this as ConfirmEnrolmentProcedureArgs,
    );
  }
}

extension ConfirmEnrolmentProcedureArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, ConfirmEnrolmentProcedureArgs, $Out> {
  ConfirmEnrolmentProcedureArgsCopyWith<$R, ConfirmEnrolmentProcedureArgs, $Out>
      get $asConfirmEnrolmentProcedureArgs => $base.as(
            (v, t, t2) =>
                _ConfirmEnrolmentProcedureArgsCopyWithImpl<$R, $Out>(v, t, t2),
          );
}

abstract class ConfirmEnrolmentProcedureArgsCopyWith<
    $R,
    $In extends ConfirmEnrolmentProcedureArgs,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  ConfirmEnrolmentArgsCopyWith<$R, ConfirmEnrolmentArgs, ConfirmEnrolmentArgs>
      get args;
  $R call({ConfirmEnrolmentArgs? args});
  ConfirmEnrolmentProcedureArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _ConfirmEnrolmentProcedureArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, ConfirmEnrolmentProcedureArgs, $Out>
    implements
        ConfirmEnrolmentProcedureArgsCopyWith<$R, ConfirmEnrolmentProcedureArgs,
            $Out> {
  _ConfirmEnrolmentProcedureArgsCopyWithImpl(
    super.value,
    super.then,
    super.then2,
  );

  @override
  late final ClassMapperBase<ConfirmEnrolmentProcedureArgs> $mapper =
      ConfirmEnrolmentProcedureArgsMapper.ensureInitialized();
  @override
  ConfirmEnrolmentArgsCopyWith<$R, ConfirmEnrolmentArgs, ConfirmEnrolmentArgs>
      get args => $value.args.copyWith.$chain((v) => call(args: v));
  @override
  $R call({ConfirmEnrolmentArgs? args}) =>
      $apply(FieldCopyWithData({if (args != null) #args: args}));
  @override
  ConfirmEnrolmentProcedureArgs $make(CopyWithData data) =>
      ConfirmEnrolmentProcedureArgs(args: data.get(#args, or: $value.args));

  @override
  ConfirmEnrolmentProcedureArgsCopyWith<$R2, ConfirmEnrolmentProcedureArgs,
      $Out2> $chain<$R2, $Out2>(
          Then<$Out2, $R2> t) =>
      _ConfirmEnrolmentProcedureArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class ConfirmEnrolmentArgsMapper extends ClassMapperBase<ConfirmEnrolmentArgs> {
  ConfirmEnrolmentArgsMapper._();

  static ConfirmEnrolmentArgsMapper? _instance;
  static ConfirmEnrolmentArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ConfirmEnrolmentArgsMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'ConfirmEnrolmentArgs';

  static String _$enrolmentId(ConfirmEnrolmentArgs v) => v.enrolmentId;
  static const Field<ConfirmEnrolmentArgs, String> _f$enrolmentId = Field(
    'enrolmentId',
    _$enrolmentId,
  );
  static String _$otp(ConfirmEnrolmentArgs v) => v.otp;
  static const Field<ConfirmEnrolmentArgs, String> _f$otp = Field('otp', _$otp);
  static String _$ambient(ConfirmEnrolmentArgs v) => v.ambient;
  static const Field<ConfirmEnrolmentArgs, String> _f$ambient = Field(
    'ambient',
    _$ambient,
  );
  static String? _$userPresent(ConfirmEnrolmentArgs v) => v.userPresent;
  static const Field<ConfirmEnrolmentArgs, String> _f$userPresent = Field(
    'userPresent',
    _$userPresent,
    opt: true,
  );

  @override
  final MappableFields<ConfirmEnrolmentArgs> fields = const {
    #enrolmentId: _f$enrolmentId,
    #otp: _f$otp,
    #ambient: _f$ambient,
    #userPresent: _f$userPresent,
  };

  static ConfirmEnrolmentArgs _instantiate(DecodingData data) {
    return ConfirmEnrolmentArgs(
      enrolmentId: data.dec(_f$enrolmentId),
      otp: data.dec(_f$otp),
      ambient: data.dec(_f$ambient),
      userPresent: data.dec(_f$userPresent),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin ConfirmEnrolmentArgsMappable {
  ConfirmEnrolmentArgsCopyWith<ConfirmEnrolmentArgs, ConfirmEnrolmentArgs,
      ConfirmEnrolmentArgs> get copyWith => _ConfirmEnrolmentArgsCopyWithImpl<
          ConfirmEnrolmentArgs, ConfirmEnrolmentArgs>(
      this as ConfirmEnrolmentArgs, $identity, $identity);
  @override
  bool operator ==(Object other) {
    return ConfirmEnrolmentArgsMapper.ensureInitialized().equalsValue(
      this as ConfirmEnrolmentArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return ConfirmEnrolmentArgsMapper.ensureInitialized().hashValue(
      this as ConfirmEnrolmentArgs,
    );
  }
}

extension ConfirmEnrolmentArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, ConfirmEnrolmentArgs, $Out> {
  ConfirmEnrolmentArgsCopyWith<$R, ConfirmEnrolmentArgs, $Out>
      get $asConfirmEnrolmentArgs => $base.as(
            (v, t, t2) => _ConfirmEnrolmentArgsCopyWithImpl<$R, $Out>(v, t, t2),
          );
}

abstract class ConfirmEnrolmentArgsCopyWith<
    $R,
    $In extends ConfirmEnrolmentArgs,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  $R call({
    String? enrolmentId,
    String? otp,
    String? ambient,
    String? userPresent,
  });
  ConfirmEnrolmentArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _ConfirmEnrolmentArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, ConfirmEnrolmentArgs, $Out>
    implements ConfirmEnrolmentArgsCopyWith<$R, ConfirmEnrolmentArgs, $Out> {
  _ConfirmEnrolmentArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<ConfirmEnrolmentArgs> $mapper =
      ConfirmEnrolmentArgsMapper.ensureInitialized();
  @override
  $R call({
    String? enrolmentId,
    String? otp,
    String? ambient,
    Object? userPresent = $none,
  }) =>
      $apply(
        FieldCopyWithData({
          if (enrolmentId != null) #enrolmentId: enrolmentId,
          if (otp != null) #otp: otp,
          if (ambient != null) #ambient: ambient,
          if (userPresent != $none) #userPresent: userPresent,
        }),
      );
  @override
  ConfirmEnrolmentArgs $make(CopyWithData data) => ConfirmEnrolmentArgs(
        enrolmentId: data.get(#enrolmentId, or: $value.enrolmentId),
        otp: data.get(#otp, or: $value.otp),
        ambient: data.get(#ambient, or: $value.ambient),
        userPresent: data.get(#userPresent, or: $value.userPresent),
      );

  @override
  ConfirmEnrolmentArgsCopyWith<$R2, ConfirmEnrolmentArgs, $Out2>
      $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
          _ConfirmEnrolmentArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class BeginRenewalProcedureArgsMapper
    extends ClassMapperBase<BeginRenewalProcedureArgs> {
  BeginRenewalProcedureArgsMapper._();

  static BeginRenewalProcedureArgsMapper? _instance;
  static BeginRenewalProcedureArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = BeginRenewalProcedureArgsMapper._(),
      );
      BeginRenewalArgsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'BeginRenewalProcedureArgs';

  static BeginRenewalArgs _$args(BeginRenewalProcedureArgs v) => v.args;
  static const Field<BeginRenewalProcedureArgs, BeginRenewalArgs> _f$args =
      Field('args', _$args);

  @override
  final MappableFields<BeginRenewalProcedureArgs> fields = const {
    #args: _f$args,
  };

  static BeginRenewalProcedureArgs _instantiate(DecodingData data) {
    return BeginRenewalProcedureArgs(args: data.dec(_f$args));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin BeginRenewalProcedureArgsMappable {
  BeginRenewalProcedureArgsCopyWith<BeginRenewalProcedureArgs,
          BeginRenewalProcedureArgs, BeginRenewalProcedureArgs>
      get copyWith => _BeginRenewalProcedureArgsCopyWithImpl<
              BeginRenewalProcedureArgs, BeginRenewalProcedureArgs>(
          this as BeginRenewalProcedureArgs, $identity, $identity);
  @override
  bool operator ==(Object other) {
    return BeginRenewalProcedureArgsMapper.ensureInitialized().equalsValue(
      this as BeginRenewalProcedureArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return BeginRenewalProcedureArgsMapper.ensureInitialized().hashValue(
      this as BeginRenewalProcedureArgs,
    );
  }
}

extension BeginRenewalProcedureArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, BeginRenewalProcedureArgs, $Out> {
  BeginRenewalProcedureArgsCopyWith<$R, BeginRenewalProcedureArgs, $Out>
      get $asBeginRenewalProcedureArgs => $base.as(
            (v, t, t2) =>
                _BeginRenewalProcedureArgsCopyWithImpl<$R, $Out>(v, t, t2),
          );
}

abstract class BeginRenewalProcedureArgsCopyWith<
    $R,
    $In extends BeginRenewalProcedureArgs,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  BeginRenewalArgsCopyWith<$R, BeginRenewalArgs, BeginRenewalArgs> get args;
  $R call({BeginRenewalArgs? args});
  BeginRenewalProcedureArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _BeginRenewalProcedureArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, BeginRenewalProcedureArgs, $Out>
    implements
        BeginRenewalProcedureArgsCopyWith<$R, BeginRenewalProcedureArgs, $Out> {
  _BeginRenewalProcedureArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<BeginRenewalProcedureArgs> $mapper =
      BeginRenewalProcedureArgsMapper.ensureInitialized();
  @override
  BeginRenewalArgsCopyWith<$R, BeginRenewalArgs, BeginRenewalArgs> get args =>
      $value.args.copyWith.$chain((v) => call(args: v));
  @override
  $R call({BeginRenewalArgs? args}) =>
      $apply(FieldCopyWithData({if (args != null) #args: args}));
  @override
  BeginRenewalProcedureArgs $make(CopyWithData data) =>
      BeginRenewalProcedureArgs(args: data.get(#args, or: $value.args));

  @override
  BeginRenewalProcedureArgsCopyWith<$R2, BeginRenewalProcedureArgs, $Out2>
      $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
          _BeginRenewalProcedureArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class BeginRenewalArgsMapper extends ClassMapperBase<BeginRenewalArgs> {
  BeginRenewalArgsMapper._();

  static BeginRenewalArgsMapper? _instance;
  static BeginRenewalArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = BeginRenewalArgsMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'BeginRenewalArgs';

  static String _$deviceId(BeginRenewalArgs v) => v.deviceId;
  static const Field<BeginRenewalArgs, String> _f$deviceId = Field(
    'deviceId',
    _$deviceId,
  );
  static String _$role(BeginRenewalArgs v) => v.role;
  static const Field<BeginRenewalArgs, String> _f$role = Field('role', _$role);

  @override
  final MappableFields<BeginRenewalArgs> fields = const {
    #deviceId: _f$deviceId,
    #role: _f$role,
  };

  static BeginRenewalArgs _instantiate(DecodingData data) {
    return BeginRenewalArgs(
      deviceId: data.dec(_f$deviceId),
      role: data.dec(_f$role),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin BeginRenewalArgsMappable {
  BeginRenewalArgsCopyWith<BeginRenewalArgs, BeginRenewalArgs, BeginRenewalArgs>
      get copyWith =>
          _BeginRenewalArgsCopyWithImpl<BeginRenewalArgs, BeginRenewalArgs>(
            this as BeginRenewalArgs,
            $identity,
            $identity,
          );
  @override
  bool operator ==(Object other) {
    return BeginRenewalArgsMapper.ensureInitialized().equalsValue(
      this as BeginRenewalArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return BeginRenewalArgsMapper.ensureInitialized().hashValue(
      this as BeginRenewalArgs,
    );
  }
}

extension BeginRenewalArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, BeginRenewalArgs, $Out> {
  BeginRenewalArgsCopyWith<$R, BeginRenewalArgs, $Out>
      get $asBeginRenewalArgs => $base
          .as((v, t, t2) => _BeginRenewalArgsCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class BeginRenewalArgsCopyWith<$R, $In extends BeginRenewalArgs, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({String? deviceId, String? role});
  BeginRenewalArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _BeginRenewalArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, BeginRenewalArgs, $Out>
    implements BeginRenewalArgsCopyWith<$R, BeginRenewalArgs, $Out> {
  _BeginRenewalArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<BeginRenewalArgs> $mapper =
      BeginRenewalArgsMapper.ensureInitialized();
  @override
  $R call({String? deviceId, String? role}) => $apply(
        FieldCopyWithData({
          if (deviceId != null) #deviceId: deviceId,
          if (role != null) #role: role,
        }),
      );
  @override
  BeginRenewalArgs $make(CopyWithData data) => BeginRenewalArgs(
        deviceId: data.get(#deviceId, or: $value.deviceId),
        role: data.get(#role, or: $value.role),
      );

  @override
  BeginRenewalArgsCopyWith<$R2, BeginRenewalArgs, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _BeginRenewalArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class ConfirmRenewalProcedureArgsMapper
    extends ClassMapperBase<ConfirmRenewalProcedureArgs> {
  ConfirmRenewalProcedureArgsMapper._();

  static ConfirmRenewalProcedureArgsMapper? _instance;
  static ConfirmRenewalProcedureArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = ConfirmRenewalProcedureArgsMapper._(),
      );
      ConfirmRenewalArgsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'ConfirmRenewalProcedureArgs';

  static ConfirmRenewalArgs _$args(ConfirmRenewalProcedureArgs v) => v.args;
  static const Field<ConfirmRenewalProcedureArgs, ConfirmRenewalArgs> _f$args =
      Field('args', _$args);

  @override
  final MappableFields<ConfirmRenewalProcedureArgs> fields = const {
    #args: _f$args,
  };

  static ConfirmRenewalProcedureArgs _instantiate(DecodingData data) {
    return ConfirmRenewalProcedureArgs(args: data.dec(_f$args));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin ConfirmRenewalProcedureArgsMappable {
  ConfirmRenewalProcedureArgsCopyWith<ConfirmRenewalProcedureArgs,
          ConfirmRenewalProcedureArgs, ConfirmRenewalProcedureArgs>
      get copyWith => _ConfirmRenewalProcedureArgsCopyWithImpl<
              ConfirmRenewalProcedureArgs, ConfirmRenewalProcedureArgs>(
          this as ConfirmRenewalProcedureArgs, $identity, $identity);
  @override
  bool operator ==(Object other) {
    return ConfirmRenewalProcedureArgsMapper.ensureInitialized().equalsValue(
      this as ConfirmRenewalProcedureArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return ConfirmRenewalProcedureArgsMapper.ensureInitialized().hashValue(
      this as ConfirmRenewalProcedureArgs,
    );
  }
}

extension ConfirmRenewalProcedureArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, ConfirmRenewalProcedureArgs, $Out> {
  ConfirmRenewalProcedureArgsCopyWith<$R, ConfirmRenewalProcedureArgs, $Out>
      get $asConfirmRenewalProcedureArgs => $base.as(
            (v, t, t2) =>
                _ConfirmRenewalProcedureArgsCopyWithImpl<$R, $Out>(v, t, t2),
          );
}

abstract class ConfirmRenewalProcedureArgsCopyWith<
    $R,
    $In extends ConfirmRenewalProcedureArgs,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  ConfirmRenewalArgsCopyWith<$R, ConfirmRenewalArgs, ConfirmRenewalArgs>
      get args;
  $R call({ConfirmRenewalArgs? args});
  ConfirmRenewalProcedureArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _ConfirmRenewalProcedureArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, ConfirmRenewalProcedureArgs, $Out>
    implements
        ConfirmRenewalProcedureArgsCopyWith<$R, ConfirmRenewalProcedureArgs,
            $Out> {
  _ConfirmRenewalProcedureArgsCopyWithImpl(
    super.value,
    super.then,
    super.then2,
  );

  @override
  late final ClassMapperBase<ConfirmRenewalProcedureArgs> $mapper =
      ConfirmRenewalProcedureArgsMapper.ensureInitialized();
  @override
  ConfirmRenewalArgsCopyWith<$R, ConfirmRenewalArgs, ConfirmRenewalArgs>
      get args => $value.args.copyWith.$chain((v) => call(args: v));
  @override
  $R call({ConfirmRenewalArgs? args}) =>
      $apply(FieldCopyWithData({if (args != null) #args: args}));
  @override
  ConfirmRenewalProcedureArgs $make(CopyWithData data) =>
      ConfirmRenewalProcedureArgs(args: data.get(#args, or: $value.args));

  @override
  ConfirmRenewalProcedureArgsCopyWith<$R2, ConfirmRenewalProcedureArgs, $Out2>
      $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
          _ConfirmRenewalProcedureArgsCopyWithImpl<$R2, $Out2>(
              $value, $cast, t);
}

class ConfirmRenewalArgsMapper extends ClassMapperBase<ConfirmRenewalArgs> {
  ConfirmRenewalArgsMapper._();

  static ConfirmRenewalArgsMapper? _instance;
  static ConfirmRenewalArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ConfirmRenewalArgsMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'ConfirmRenewalArgs';

  static String _$challengeId(ConfirmRenewalArgs v) => v.challengeId;
  static const Field<ConfirmRenewalArgs, String> _f$challengeId = Field(
    'challengeId',
    _$challengeId,
  );
  static String _$signature(ConfirmRenewalArgs v) => v.signature;
  static const Field<ConfirmRenewalArgs, String> _f$signature = Field(
    'signature',
    _$signature,
  );

  @override
  final MappableFields<ConfirmRenewalArgs> fields = const {
    #challengeId: _f$challengeId,
    #signature: _f$signature,
  };

  static ConfirmRenewalArgs _instantiate(DecodingData data) {
    return ConfirmRenewalArgs(
      challengeId: data.dec(_f$challengeId),
      signature: data.dec(_f$signature),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin ConfirmRenewalArgsMappable {
  ConfirmRenewalArgsCopyWith<ConfirmRenewalArgs, ConfirmRenewalArgs,
      ConfirmRenewalArgs> get copyWith => _ConfirmRenewalArgsCopyWithImpl<
          ConfirmRenewalArgs, ConfirmRenewalArgs>(
        this as ConfirmRenewalArgs,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return ConfirmRenewalArgsMapper.ensureInitialized().equalsValue(
      this as ConfirmRenewalArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return ConfirmRenewalArgsMapper.ensureInitialized().hashValue(
      this as ConfirmRenewalArgs,
    );
  }
}

extension ConfirmRenewalArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, ConfirmRenewalArgs, $Out> {
  ConfirmRenewalArgsCopyWith<$R, ConfirmRenewalArgs, $Out>
      get $asConfirmRenewalArgs => $base.as(
            (v, t, t2) => _ConfirmRenewalArgsCopyWithImpl<$R, $Out>(v, t, t2),
          );
}

abstract class ConfirmRenewalArgsCopyWith<$R, $In extends ConfirmRenewalArgs,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  $R call({String? challengeId, String? signature});
  ConfirmRenewalArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _ConfirmRenewalArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, ConfirmRenewalArgs, $Out>
    implements ConfirmRenewalArgsCopyWith<$R, ConfirmRenewalArgs, $Out> {
  _ConfirmRenewalArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<ConfirmRenewalArgs> $mapper =
      ConfirmRenewalArgsMapper.ensureInitialized();
  @override
  $R call({String? challengeId, String? signature}) => $apply(
        FieldCopyWithData({
          if (challengeId != null) #challengeId: challengeId,
          if (signature != null) #signature: signature,
        }),
      );
  @override
  ConfirmRenewalArgs $make(CopyWithData data) => ConfirmRenewalArgs(
        challengeId: data.get(#challengeId, or: $value.challengeId),
        signature: data.get(#signature, or: $value.signature),
      );

  @override
  ConfirmRenewalArgsCopyWith<$R2, ConfirmRenewalArgs, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _ConfirmRenewalArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class RevokeDeviceArgsMapper extends ClassMapperBase<RevokeDeviceArgs> {
  RevokeDeviceArgsMapper._();

  static RevokeDeviceArgsMapper? _instance;
  static RevokeDeviceArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RevokeDeviceArgsMapper._());
      RevokeArgsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'RevokeDeviceArgs';

  static RevokeArgs _$args(RevokeDeviceArgs v) => v.args;
  static const Field<RevokeDeviceArgs, RevokeArgs> _f$args = Field(
    'args',
    _$args,
  );

  @override
  final MappableFields<RevokeDeviceArgs> fields = const {#args: _f$args};

  static RevokeDeviceArgs _instantiate(DecodingData data) {
    return RevokeDeviceArgs(args: data.dec(_f$args));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin RevokeDeviceArgsMappable {
  RevokeDeviceArgsCopyWith<RevokeDeviceArgs, RevokeDeviceArgs, RevokeDeviceArgs>
      get copyWith =>
          _RevokeDeviceArgsCopyWithImpl<RevokeDeviceArgs, RevokeDeviceArgs>(
            this as RevokeDeviceArgs,
            $identity,
            $identity,
          );
  @override
  bool operator ==(Object other) {
    return RevokeDeviceArgsMapper.ensureInitialized().equalsValue(
      this as RevokeDeviceArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return RevokeDeviceArgsMapper.ensureInitialized().hashValue(
      this as RevokeDeviceArgs,
    );
  }
}

extension RevokeDeviceArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, RevokeDeviceArgs, $Out> {
  RevokeDeviceArgsCopyWith<$R, RevokeDeviceArgs, $Out>
      get $asRevokeDeviceArgs => $base
          .as((v, t, t2) => _RevokeDeviceArgsCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class RevokeDeviceArgsCopyWith<$R, $In extends RevokeDeviceArgs, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  RevokeArgsCopyWith<$R, RevokeArgs, RevokeArgs> get args;
  $R call({RevokeArgs? args});
  RevokeDeviceArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _RevokeDeviceArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, RevokeDeviceArgs, $Out>
    implements RevokeDeviceArgsCopyWith<$R, RevokeDeviceArgs, $Out> {
  _RevokeDeviceArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<RevokeDeviceArgs> $mapper =
      RevokeDeviceArgsMapper.ensureInitialized();
  @override
  RevokeArgsCopyWith<$R, RevokeArgs, RevokeArgs> get args =>
      $value.args.copyWith.$chain((v) => call(args: v));
  @override
  $R call({RevokeArgs? args}) =>
      $apply(FieldCopyWithData({if (args != null) #args: args}));
  @override
  RevokeDeviceArgs $make(CopyWithData data) =>
      RevokeDeviceArgs(args: data.get(#args, or: $value.args));

  @override
  RevokeDeviceArgsCopyWith<$R2, RevokeDeviceArgs, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _RevokeDeviceArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class RevokeArgsMapper extends ClassMapperBase<RevokeArgs> {
  RevokeArgsMapper._();

  static RevokeArgsMapper? _instance;
  static RevokeArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RevokeArgsMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'RevokeArgs';

  static String _$deviceId(RevokeArgs v) => v.deviceId;
  static const Field<RevokeArgs, String> _f$deviceId = Field(
    'deviceId',
    _$deviceId,
  );

  @override
  final MappableFields<RevokeArgs> fields = const {#deviceId: _f$deviceId};

  static RevokeArgs _instantiate(DecodingData data) {
    return RevokeArgs(deviceId: data.dec(_f$deviceId));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin RevokeArgsMappable {
  RevokeArgsCopyWith<RevokeArgs, RevokeArgs, RevokeArgs> get copyWith =>
      _RevokeArgsCopyWithImpl<RevokeArgs, RevokeArgs>(
        this as RevokeArgs,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return RevokeArgsMapper.ensureInitialized().equalsValue(
      this as RevokeArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return RevokeArgsMapper.ensureInitialized().hashValue(this as RevokeArgs);
  }
}

extension RevokeArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, RevokeArgs, $Out> {
  RevokeArgsCopyWith<$R, RevokeArgs, $Out> get $asRevokeArgs =>
      $base.as((v, t, t2) => _RevokeArgsCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class RevokeArgsCopyWith<$R, $In extends RevokeArgs, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({String? deviceId});
  RevokeArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _RevokeArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, RevokeArgs, $Out>
    implements RevokeArgsCopyWith<$R, RevokeArgs, $Out> {
  _RevokeArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<RevokeArgs> $mapper =
      RevokeArgsMapper.ensureInitialized();
  @override
  $R call({String? deviceId}) =>
      $apply(FieldCopyWithData({if (deviceId != null) #deviceId: deviceId}));
  @override
  RevokeArgs $make(CopyWithData data) =>
      RevokeArgs(deviceId: data.get(#deviceId, or: $value.deviceId));

  @override
  RevokeArgsCopyWith<$R2, RevokeArgs, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _RevokeArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class AccountArgsMapper extends ClassMapperBase<AccountArgs> {
  AccountArgsMapper._();

  static AccountArgsMapper? _instance;
  static AccountArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = AccountArgsMapper._());
      NoArgsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'AccountArgs';

  static NoArgs _$args(AccountArgs v) => v.args;
  static const Field<AccountArgs, NoArgs> _f$args = Field('args', _$args);

  @override
  final MappableFields<AccountArgs> fields = const {#args: _f$args};

  static AccountArgs _instantiate(DecodingData data) {
    return AccountArgs(args: data.dec(_f$args));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin AccountArgsMappable {
  AccountArgsCopyWith<AccountArgs, AccountArgs, AccountArgs> get copyWith =>
      _AccountArgsCopyWithImpl<AccountArgs, AccountArgs>(
        this as AccountArgs,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return AccountArgsMapper.ensureInitialized().equalsValue(
      this as AccountArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return AccountArgsMapper.ensureInitialized().hashValue(this as AccountArgs);
  }
}

extension AccountArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, AccountArgs, $Out> {
  AccountArgsCopyWith<$R, AccountArgs, $Out> get $asAccountArgs =>
      $base.as((v, t, t2) => _AccountArgsCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class AccountArgsCopyWith<$R, $In extends AccountArgs, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  NoArgsCopyWith<$R, NoArgs, NoArgs> get args;
  $R call({NoArgs? args});
  AccountArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _AccountArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, AccountArgs, $Out>
    implements AccountArgsCopyWith<$R, AccountArgs, $Out> {
  _AccountArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<AccountArgs> $mapper =
      AccountArgsMapper.ensureInitialized();
  @override
  NoArgsCopyWith<$R, NoArgs, NoArgs> get args =>
      $value.args.copyWith.$chain((v) => call(args: v));
  @override
  $R call({NoArgs? args}) =>
      $apply(FieldCopyWithData({if (args != null) #args: args}));
  @override
  AccountArgs $make(CopyWithData data) =>
      AccountArgs(args: data.get(#args, or: $value.args));

  @override
  AccountArgsCopyWith<$R2, AccountArgs, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _AccountArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class NoArgsMapper extends ClassMapperBase<NoArgs> {
  NoArgsMapper._();

  static NoArgsMapper? _instance;
  static NoArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = NoArgsMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'NoArgs';

  static int? _$unused(NoArgs v) => v.unused;
  static const Field<NoArgs, int> _f$unused = Field(
    'unused',
    _$unused,
    opt: true,
  );

  @override
  final MappableFields<NoArgs> fields = const {#unused: _f$unused};

  static NoArgs _instantiate(DecodingData data) {
    return NoArgs(unused: data.dec(_f$unused));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin NoArgsMappable {
  NoArgsCopyWith<NoArgs, NoArgs, NoArgs> get copyWith =>
      _NoArgsCopyWithImpl<NoArgs, NoArgs>(this as NoArgs, $identity, $identity);
  @override
  bool operator ==(Object other) {
    return NoArgsMapper.ensureInitialized().equalsValue(this as NoArgs, other);
  }

  @override
  int get hashCode {
    return NoArgsMapper.ensureInitialized().hashValue(this as NoArgs);
  }
}

extension NoArgsValueCopy<$R, $Out> on ObjectCopyWith<$R, NoArgs, $Out> {
  NoArgsCopyWith<$R, NoArgs, $Out> get $asNoArgs =>
      $base.as((v, t, t2) => _NoArgsCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class NoArgsCopyWith<$R, $In extends NoArgs, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({int? unused});
  NoArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _NoArgsCopyWithImpl<$R, $Out> extends ClassCopyWithBase<$R, NoArgs, $Out>
    implements NoArgsCopyWith<$R, NoArgs, $Out> {
  _NoArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<NoArgs> $mapper = NoArgsMapper.ensureInitialized();
  @override
  $R call({Object? unused = $none}) =>
      $apply(FieldCopyWithData({if (unused != $none) #unused: unused}));
  @override
  NoArgs $make(CopyWithData data) =>
      NoArgs(unused: data.get(#unused, or: $value.unused));

  @override
  NoArgsCopyWith<$R2, NoArgs, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _NoArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class ListOrdersProcedureArgsMapper
    extends ClassMapperBase<ListOrdersProcedureArgs> {
  ListOrdersProcedureArgsMapper._();

  static ListOrdersProcedureArgsMapper? _instance;
  static ListOrdersProcedureArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = ListOrdersProcedureArgsMapper._(),
      );
      ListOrdersArgsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'ListOrdersProcedureArgs';

  static ListOrdersArgs _$args(ListOrdersProcedureArgs v) => v.args;
  static const Field<ListOrdersProcedureArgs, ListOrdersArgs> _f$args = Field(
    'args',
    _$args,
  );

  @override
  final MappableFields<ListOrdersProcedureArgs> fields = const {#args: _f$args};

  static ListOrdersProcedureArgs _instantiate(DecodingData data) {
    return ListOrdersProcedureArgs(args: data.dec(_f$args));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin ListOrdersProcedureArgsMappable {
  ListOrdersProcedureArgsCopyWith<ListOrdersProcedureArgs,
          ListOrdersProcedureArgs, ListOrdersProcedureArgs>
      get copyWith => _ListOrdersProcedureArgsCopyWithImpl<
              ListOrdersProcedureArgs, ListOrdersProcedureArgs>(
          this as ListOrdersProcedureArgs, $identity, $identity);
  @override
  bool operator ==(Object other) {
    return ListOrdersProcedureArgsMapper.ensureInitialized().equalsValue(
      this as ListOrdersProcedureArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return ListOrdersProcedureArgsMapper.ensureInitialized().hashValue(
      this as ListOrdersProcedureArgs,
    );
  }
}

extension ListOrdersProcedureArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, ListOrdersProcedureArgs, $Out> {
  ListOrdersProcedureArgsCopyWith<$R, ListOrdersProcedureArgs, $Out>
      get $asListOrdersProcedureArgs => $base.as(
            (v, t, t2) =>
                _ListOrdersProcedureArgsCopyWithImpl<$R, $Out>(v, t, t2),
          );
}

abstract class ListOrdersProcedureArgsCopyWith<
    $R,
    $In extends ListOrdersProcedureArgs,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  ListOrdersArgsCopyWith<$R, ListOrdersArgs, ListOrdersArgs> get args;
  $R call({ListOrdersArgs? args});
  ListOrdersProcedureArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _ListOrdersProcedureArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, ListOrdersProcedureArgs, $Out>
    implements
        ListOrdersProcedureArgsCopyWith<$R, ListOrdersProcedureArgs, $Out> {
  _ListOrdersProcedureArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<ListOrdersProcedureArgs> $mapper =
      ListOrdersProcedureArgsMapper.ensureInitialized();
  @override
  ListOrdersArgsCopyWith<$R, ListOrdersArgs, ListOrdersArgs> get args =>
      $value.args.copyWith.$chain((v) => call(args: v));
  @override
  $R call({ListOrdersArgs? args}) =>
      $apply(FieldCopyWithData({if (args != null) #args: args}));
  @override
  ListOrdersProcedureArgs $make(CopyWithData data) =>
      ListOrdersProcedureArgs(args: data.get(#args, or: $value.args));

  @override
  ListOrdersProcedureArgsCopyWith<$R2, ListOrdersProcedureArgs, $Out2>
      $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
          _ListOrdersProcedureArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class ListOrdersArgsMapper extends ClassMapperBase<ListOrdersArgs> {
  ListOrdersArgsMapper._();

  static ListOrdersArgsMapper? _instance;
  static ListOrdersArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ListOrdersArgsMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'ListOrdersArgs';

  static int? _$limit(ListOrdersArgs v) => v.limit;
  static const Field<ListOrdersArgs, int> _f$limit = Field(
    'limit',
    _$limit,
    opt: true,
  );

  @override
  final MappableFields<ListOrdersArgs> fields = const {#limit: _f$limit};

  static ListOrdersArgs _instantiate(DecodingData data) {
    return ListOrdersArgs(limit: data.dec(_f$limit));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin ListOrdersArgsMappable {
  ListOrdersArgsCopyWith<ListOrdersArgs, ListOrdersArgs, ListOrdersArgs>
      get copyWith =>
          _ListOrdersArgsCopyWithImpl<ListOrdersArgs, ListOrdersArgs>(
            this as ListOrdersArgs,
            $identity,
            $identity,
          );
  @override
  bool operator ==(Object other) {
    return ListOrdersArgsMapper.ensureInitialized().equalsValue(
      this as ListOrdersArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return ListOrdersArgsMapper.ensureInitialized().hashValue(
      this as ListOrdersArgs,
    );
  }
}

extension ListOrdersArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, ListOrdersArgs, $Out> {
  ListOrdersArgsCopyWith<$R, ListOrdersArgs, $Out> get $asListOrdersArgs =>
      $base.as((v, t, t2) => _ListOrdersArgsCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class ListOrdersArgsCopyWith<$R, $In extends ListOrdersArgs, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({int? limit});
  ListOrdersArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _ListOrdersArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, ListOrdersArgs, $Out>
    implements ListOrdersArgsCopyWith<$R, ListOrdersArgs, $Out> {
  _ListOrdersArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<ListOrdersArgs> $mapper =
      ListOrdersArgsMapper.ensureInitialized();
  @override
  $R call({Object? limit = $none}) =>
      $apply(FieldCopyWithData({if (limit != $none) #limit: limit}));
  @override
  ListOrdersArgs $make(CopyWithData data) =>
      ListOrdersArgs(limit: data.get(#limit, or: $value.limit));

  @override
  ListOrdersArgsCopyWith<$R2, ListOrdersArgs, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _ListOrdersArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class GetOrderProcedureArgsMapper
    extends ClassMapperBase<GetOrderProcedureArgs> {
  GetOrderProcedureArgsMapper._();

  static GetOrderProcedureArgsMapper? _instance;
  static GetOrderProcedureArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = GetOrderProcedureArgsMapper._());
      GetOrderArgsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'GetOrderProcedureArgs';

  static GetOrderArgs _$args(GetOrderProcedureArgs v) => v.args;
  static const Field<GetOrderProcedureArgs, GetOrderArgs> _f$args = Field(
    'args',
    _$args,
  );

  @override
  final MappableFields<GetOrderProcedureArgs> fields = const {#args: _f$args};

  static GetOrderProcedureArgs _instantiate(DecodingData data) {
    return GetOrderProcedureArgs(args: data.dec(_f$args));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin GetOrderProcedureArgsMappable {
  GetOrderProcedureArgsCopyWith<GetOrderProcedureArgs, GetOrderProcedureArgs,
      GetOrderProcedureArgs> get copyWith => _GetOrderProcedureArgsCopyWithImpl<
          GetOrderProcedureArgs, GetOrderProcedureArgs>(
      this as GetOrderProcedureArgs, $identity, $identity);
  @override
  bool operator ==(Object other) {
    return GetOrderProcedureArgsMapper.ensureInitialized().equalsValue(
      this as GetOrderProcedureArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return GetOrderProcedureArgsMapper.ensureInitialized().hashValue(
      this as GetOrderProcedureArgs,
    );
  }
}

extension GetOrderProcedureArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, GetOrderProcedureArgs, $Out> {
  GetOrderProcedureArgsCopyWith<$R, GetOrderProcedureArgs, $Out>
      get $asGetOrderProcedureArgs => $base.as(
            (v, t, t2) =>
                _GetOrderProcedureArgsCopyWithImpl<$R, $Out>(v, t, t2),
          );
}

abstract class GetOrderProcedureArgsCopyWith<
    $R,
    $In extends GetOrderProcedureArgs,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  GetOrderArgsCopyWith<$R, GetOrderArgs, GetOrderArgs> get args;
  $R call({GetOrderArgs? args});
  GetOrderProcedureArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _GetOrderProcedureArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, GetOrderProcedureArgs, $Out>
    implements GetOrderProcedureArgsCopyWith<$R, GetOrderProcedureArgs, $Out> {
  _GetOrderProcedureArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<GetOrderProcedureArgs> $mapper =
      GetOrderProcedureArgsMapper.ensureInitialized();
  @override
  GetOrderArgsCopyWith<$R, GetOrderArgs, GetOrderArgs> get args =>
      $value.args.copyWith.$chain((v) => call(args: v));
  @override
  $R call({GetOrderArgs? args}) =>
      $apply(FieldCopyWithData({if (args != null) #args: args}));
  @override
  GetOrderProcedureArgs $make(CopyWithData data) =>
      GetOrderProcedureArgs(args: data.get(#args, or: $value.args));

  @override
  GetOrderProcedureArgsCopyWith<$R2, GetOrderProcedureArgs, $Out2>
      $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
          _GetOrderProcedureArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class GetOrderArgsMapper extends ClassMapperBase<GetOrderArgs> {
  GetOrderArgsMapper._();

  static GetOrderArgsMapper? _instance;
  static GetOrderArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = GetOrderArgsMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'GetOrderArgs';

  static int _$id(GetOrderArgs v) => v.id;
  static const Field<GetOrderArgs, int> _f$id = Field('id', _$id);

  @override
  final MappableFields<GetOrderArgs> fields = const {#id: _f$id};

  static GetOrderArgs _instantiate(DecodingData data) {
    return GetOrderArgs(id: data.dec(_f$id));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin GetOrderArgsMappable {
  GetOrderArgsCopyWith<GetOrderArgs, GetOrderArgs, GetOrderArgs> get copyWith =>
      _GetOrderArgsCopyWithImpl<GetOrderArgs, GetOrderArgs>(
        this as GetOrderArgs,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return GetOrderArgsMapper.ensureInitialized().equalsValue(
      this as GetOrderArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return GetOrderArgsMapper.ensureInitialized().hashValue(
      this as GetOrderArgs,
    );
  }
}

extension GetOrderArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, GetOrderArgs, $Out> {
  GetOrderArgsCopyWith<$R, GetOrderArgs, $Out> get $asGetOrderArgs =>
      $base.as((v, t, t2) => _GetOrderArgsCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class GetOrderArgsCopyWith<$R, $In extends GetOrderArgs, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({int? id});
  GetOrderArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _GetOrderArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, GetOrderArgs, $Out>
    implements GetOrderArgsCopyWith<$R, GetOrderArgs, $Out> {
  _GetOrderArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<GetOrderArgs> $mapper =
      GetOrderArgsMapper.ensureInitialized();
  @override
  $R call({int? id}) => $apply(FieldCopyWithData({if (id != null) #id: id}));
  @override
  GetOrderArgs $make(CopyWithData data) =>
      GetOrderArgs(id: data.get(#id, or: $value.id));

  @override
  GetOrderArgsCopyWith<$R2, GetOrderArgs, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _GetOrderArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class PlaceOrderProcedureArgsMapper
    extends ClassMapperBase<PlaceOrderProcedureArgs> {
  PlaceOrderProcedureArgsMapper._();

  static PlaceOrderProcedureArgsMapper? _instance;
  static PlaceOrderProcedureArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = PlaceOrderProcedureArgsMapper._(),
      );
      PlaceOrderArgsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'PlaceOrderProcedureArgs';

  static PlaceOrderArgs _$args(PlaceOrderProcedureArgs v) => v.args;
  static const Field<PlaceOrderProcedureArgs, PlaceOrderArgs> _f$args = Field(
    'args',
    _$args,
  );

  @override
  final MappableFields<PlaceOrderProcedureArgs> fields = const {#args: _f$args};

  static PlaceOrderProcedureArgs _instantiate(DecodingData data) {
    return PlaceOrderProcedureArgs(args: data.dec(_f$args));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin PlaceOrderProcedureArgsMappable {
  PlaceOrderProcedureArgsCopyWith<PlaceOrderProcedureArgs,
          PlaceOrderProcedureArgs, PlaceOrderProcedureArgs>
      get copyWith => _PlaceOrderProcedureArgsCopyWithImpl<
              PlaceOrderProcedureArgs, PlaceOrderProcedureArgs>(
          this as PlaceOrderProcedureArgs, $identity, $identity);
  @override
  bool operator ==(Object other) {
    return PlaceOrderProcedureArgsMapper.ensureInitialized().equalsValue(
      this as PlaceOrderProcedureArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return PlaceOrderProcedureArgsMapper.ensureInitialized().hashValue(
      this as PlaceOrderProcedureArgs,
    );
  }
}

extension PlaceOrderProcedureArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, PlaceOrderProcedureArgs, $Out> {
  PlaceOrderProcedureArgsCopyWith<$R, PlaceOrderProcedureArgs, $Out>
      get $asPlaceOrderProcedureArgs => $base.as(
            (v, t, t2) =>
                _PlaceOrderProcedureArgsCopyWithImpl<$R, $Out>(v, t, t2),
          );
}

abstract class PlaceOrderProcedureArgsCopyWith<
    $R,
    $In extends PlaceOrderProcedureArgs,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  PlaceOrderArgsCopyWith<$R, PlaceOrderArgs, PlaceOrderArgs> get args;
  $R call({PlaceOrderArgs? args});
  PlaceOrderProcedureArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _PlaceOrderProcedureArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, PlaceOrderProcedureArgs, $Out>
    implements
        PlaceOrderProcedureArgsCopyWith<$R, PlaceOrderProcedureArgs, $Out> {
  _PlaceOrderProcedureArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<PlaceOrderProcedureArgs> $mapper =
      PlaceOrderProcedureArgsMapper.ensureInitialized();
  @override
  PlaceOrderArgsCopyWith<$R, PlaceOrderArgs, PlaceOrderArgs> get args =>
      $value.args.copyWith.$chain((v) => call(args: v));
  @override
  $R call({PlaceOrderArgs? args}) =>
      $apply(FieldCopyWithData({if (args != null) #args: args}));
  @override
  PlaceOrderProcedureArgs $make(CopyWithData data) =>
      PlaceOrderProcedureArgs(args: data.get(#args, or: $value.args));

  @override
  PlaceOrderProcedureArgsCopyWith<$R2, PlaceOrderProcedureArgs, $Out2>
      $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
          _PlaceOrderProcedureArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class PlaceOrderArgsMapper extends ClassMapperBase<PlaceOrderArgs> {
  PlaceOrderArgsMapper._();

  static PlaceOrderArgsMapper? _instance;
  static PlaceOrderArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = PlaceOrderArgsMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'PlaceOrderArgs';

  static String _$item(PlaceOrderArgs v) => v.item;
  static const Field<PlaceOrderArgs, String> _f$item = Field('item', _$item);
  static int _$quantity(PlaceOrderArgs v) => v.quantity;
  static const Field<PlaceOrderArgs, int> _f$quantity = Field(
    'quantity',
    _$quantity,
  );

  @override
  final MappableFields<PlaceOrderArgs> fields = const {
    #item: _f$item,
    #quantity: _f$quantity,
  };

  static PlaceOrderArgs _instantiate(DecodingData data) {
    return PlaceOrderArgs(
      item: data.dec(_f$item),
      quantity: data.dec(_f$quantity),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin PlaceOrderArgsMappable {
  PlaceOrderArgsCopyWith<PlaceOrderArgs, PlaceOrderArgs, PlaceOrderArgs>
      get copyWith =>
          _PlaceOrderArgsCopyWithImpl<PlaceOrderArgs, PlaceOrderArgs>(
            this as PlaceOrderArgs,
            $identity,
            $identity,
          );
  @override
  bool operator ==(Object other) {
    return PlaceOrderArgsMapper.ensureInitialized().equalsValue(
      this as PlaceOrderArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return PlaceOrderArgsMapper.ensureInitialized().hashValue(
      this as PlaceOrderArgs,
    );
  }
}

extension PlaceOrderArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, PlaceOrderArgs, $Out> {
  PlaceOrderArgsCopyWith<$R, PlaceOrderArgs, $Out> get $asPlaceOrderArgs =>
      $base.as((v, t, t2) => _PlaceOrderArgsCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class PlaceOrderArgsCopyWith<$R, $In extends PlaceOrderArgs, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({String? item, int? quantity});
  PlaceOrderArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _PlaceOrderArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, PlaceOrderArgs, $Out>
    implements PlaceOrderArgsCopyWith<$R, PlaceOrderArgs, $Out> {
  _PlaceOrderArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<PlaceOrderArgs> $mapper =
      PlaceOrderArgsMapper.ensureInitialized();
  @override
  $R call({String? item, int? quantity}) => $apply(
        FieldCopyWithData({
          if (item != null) #item: item,
          if (quantity != null) #quantity: quantity,
        }),
      );
  @override
  PlaceOrderArgs $make(CopyWithData data) => PlaceOrderArgs(
        item: data.get(#item, or: $value.item),
        quantity: data.get(#quantity, or: $value.quantity),
      );

  @override
  PlaceOrderArgsCopyWith<$R2, PlaceOrderArgs, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _PlaceOrderArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class PayOrderProcedureArgsMapper
    extends ClassMapperBase<PayOrderProcedureArgs> {
  PayOrderProcedureArgsMapper._();

  static PayOrderProcedureArgsMapper? _instance;
  static PayOrderProcedureArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = PayOrderProcedureArgsMapper._());
      PayOrderArgsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'PayOrderProcedureArgs';

  static PayOrderArgs _$args(PayOrderProcedureArgs v) => v.args;
  static const Field<PayOrderProcedureArgs, PayOrderArgs> _f$args = Field(
    'args',
    _$args,
  );

  @override
  final MappableFields<PayOrderProcedureArgs> fields = const {#args: _f$args};

  static PayOrderProcedureArgs _instantiate(DecodingData data) {
    return PayOrderProcedureArgs(args: data.dec(_f$args));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin PayOrderProcedureArgsMappable {
  PayOrderProcedureArgsCopyWith<PayOrderProcedureArgs, PayOrderProcedureArgs,
      PayOrderProcedureArgs> get copyWith => _PayOrderProcedureArgsCopyWithImpl<
          PayOrderProcedureArgs, PayOrderProcedureArgs>(
      this as PayOrderProcedureArgs, $identity, $identity);
  @override
  bool operator ==(Object other) {
    return PayOrderProcedureArgsMapper.ensureInitialized().equalsValue(
      this as PayOrderProcedureArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return PayOrderProcedureArgsMapper.ensureInitialized().hashValue(
      this as PayOrderProcedureArgs,
    );
  }
}

extension PayOrderProcedureArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, PayOrderProcedureArgs, $Out> {
  PayOrderProcedureArgsCopyWith<$R, PayOrderProcedureArgs, $Out>
      get $asPayOrderProcedureArgs => $base.as(
            (v, t, t2) =>
                _PayOrderProcedureArgsCopyWithImpl<$R, $Out>(v, t, t2),
          );
}

abstract class PayOrderProcedureArgsCopyWith<
    $R,
    $In extends PayOrderProcedureArgs,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  PayOrderArgsCopyWith<$R, PayOrderArgs, PayOrderArgs> get args;
  $R call({PayOrderArgs? args});
  PayOrderProcedureArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _PayOrderProcedureArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, PayOrderProcedureArgs, $Out>
    implements PayOrderProcedureArgsCopyWith<$R, PayOrderProcedureArgs, $Out> {
  _PayOrderProcedureArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<PayOrderProcedureArgs> $mapper =
      PayOrderProcedureArgsMapper.ensureInitialized();
  @override
  PayOrderArgsCopyWith<$R, PayOrderArgs, PayOrderArgs> get args =>
      $value.args.copyWith.$chain((v) => call(args: v));
  @override
  $R call({PayOrderArgs? args}) =>
      $apply(FieldCopyWithData({if (args != null) #args: args}));
  @override
  PayOrderProcedureArgs $make(CopyWithData data) =>
      PayOrderProcedureArgs(args: data.get(#args, or: $value.args));

  @override
  PayOrderProcedureArgsCopyWith<$R2, PayOrderProcedureArgs, $Out2>
      $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
          _PayOrderProcedureArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class PayOrderArgsMapper extends ClassMapperBase<PayOrderArgs> {
  PayOrderArgsMapper._();

  static PayOrderArgsMapper? _instance;
  static PayOrderArgsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = PayOrderArgsMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'PayOrderArgs';

  static int _$id(PayOrderArgs v) => v.id;
  static const Field<PayOrderArgs, int> _f$id = Field('id', _$id);

  @override
  final MappableFields<PayOrderArgs> fields = const {#id: _f$id};

  static PayOrderArgs _instantiate(DecodingData data) {
    return PayOrderArgs(id: data.dec(_f$id));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin PayOrderArgsMappable {
  PayOrderArgsCopyWith<PayOrderArgs, PayOrderArgs, PayOrderArgs> get copyWith =>
      _PayOrderArgsCopyWithImpl<PayOrderArgs, PayOrderArgs>(
        this as PayOrderArgs,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return PayOrderArgsMapper.ensureInitialized().equalsValue(
      this as PayOrderArgs,
      other,
    );
  }

  @override
  int get hashCode {
    return PayOrderArgsMapper.ensureInitialized().hashValue(
      this as PayOrderArgs,
    );
  }
}

extension PayOrderArgsValueCopy<$R, $Out>
    on ObjectCopyWith<$R, PayOrderArgs, $Out> {
  PayOrderArgsCopyWith<$R, PayOrderArgs, $Out> get $asPayOrderArgs =>
      $base.as((v, t, t2) => _PayOrderArgsCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class PayOrderArgsCopyWith<$R, $In extends PayOrderArgs, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({int? id});
  PayOrderArgsCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _PayOrderArgsCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, PayOrderArgs, $Out>
    implements PayOrderArgsCopyWith<$R, PayOrderArgs, $Out> {
  _PayOrderArgsCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<PayOrderArgs> $mapper =
      PayOrderArgsMapper.ensureInitialized();
  @override
  $R call({int? id}) => $apply(FieldCopyWithData({if (id != null) #id: id}));
  @override
  PayOrderArgs $make(CopyWithData data) =>
      PayOrderArgs(id: data.get(#id, or: $value.id));

  @override
  PayOrderArgsCopyWith<$R2, PayOrderArgs, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _PayOrderArgsCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class AccountMapper extends ClassMapperBase<Account> {
  AccountMapper._();

  static AccountMapper? _instance;
  static AccountMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = AccountMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Account';

  static String _$userId(Account v) => v.userId;
  static const Field<Account, String> _f$userId = Field('userId', _$userId);
  static String _$phone(Account v) => v.phone;
  static const Field<Account, String> _f$phone = Field('phone', _$phone);
  static String _$deviceId(Account v) => v.deviceId;
  static const Field<Account, String> _f$deviceId = Field(
    'deviceId',
    _$deviceId,
  );
  static String _$signedWith(Account v) => v.signedWith;
  static const Field<Account, String> _f$signedWith = Field(
    'signedWith',
    _$signedWith,
  );

  @override
  final MappableFields<Account> fields = const {
    #userId: _f$userId,
    #phone: _f$phone,
    #deviceId: _f$deviceId,
    #signedWith: _f$signedWith,
  };

  static Account _instantiate(DecodingData data) {
    return Account(
      userId: data.dec(_f$userId),
      phone: data.dec(_f$phone),
      deviceId: data.dec(_f$deviceId),
      signedWith: data.dec(_f$signedWith),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin AccountMappable {
  AccountCopyWith<Account, Account, Account> get copyWith =>
      _AccountCopyWithImpl<Account, Account>(
        this as Account,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return AccountMapper.ensureInitialized().equalsValue(
      this as Account,
      other,
    );
  }

  @override
  int get hashCode {
    return AccountMapper.ensureInitialized().hashValue(this as Account);
  }
}

extension AccountValueCopy<$R, $Out> on ObjectCopyWith<$R, Account, $Out> {
  AccountCopyWith<$R, Account, $Out> get $asAccount =>
      $base.as((v, t, t2) => _AccountCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class AccountCopyWith<$R, $In extends Account, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({
    String? userId,
    String? phone,
    String? deviceId,
    String? signedWith,
  });
  AccountCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _AccountCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, Account, $Out>
    implements AccountCopyWith<$R, Account, $Out> {
  _AccountCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<Account> $mapper =
      AccountMapper.ensureInitialized();
  @override
  $R call({
    String? userId,
    String? phone,
    String? deviceId,
    String? signedWith,
  }) =>
      $apply(
        FieldCopyWithData({
          if (userId != null) #userId: userId,
          if (phone != null) #phone: phone,
          if (deviceId != null) #deviceId: deviceId,
          if (signedWith != null) #signedWith: signedWith,
        }),
      );
  @override
  Account $make(CopyWithData data) => Account(
        userId: data.get(#userId, or: $value.userId),
        phone: data.get(#phone, or: $value.phone),
        deviceId: data.get(#deviceId, or: $value.deviceId),
        signedWith: data.get(#signedWith, or: $value.signedWith),
      );

  @override
  AccountCopyWith<$R2, Account, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _AccountCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class EnrolledDeviceMapper extends ClassMapperBase<EnrolledDevice> {
  EnrolledDeviceMapper._();

  static EnrolledDeviceMapper? _instance;
  static EnrolledDeviceMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = EnrolledDeviceMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'EnrolledDevice';

  static String _$deviceId(EnrolledDevice v) => v.deviceId;
  static const Field<EnrolledDevice, String> _f$deviceId = Field(
    'deviceId',
    _$deviceId,
  );
  static String _$userId(EnrolledDevice v) => v.userId;
  static const Field<EnrolledDevice, String> _f$userId = Field(
    'userId',
    _$userId,
  );
  static String _$phone(EnrolledDevice v) => v.phone;
  static const Field<EnrolledDevice, String> _f$phone = Field('phone', _$phone);
  static String _$ambient(EnrolledDevice v) => v.ambient;
  static const Field<EnrolledDevice, String> _f$ambient = Field(
    'ambient',
    _$ambient,
  );
  static String? _$userPresent(EnrolledDevice v) => v.userPresent;
  static const Field<EnrolledDevice, String> _f$userPresent = Field(
    'userPresent',
    _$userPresent,
    opt: true,
  );

  @override
  final MappableFields<EnrolledDevice> fields = const {
    #deviceId: _f$deviceId,
    #userId: _f$userId,
    #phone: _f$phone,
    #ambient: _f$ambient,
    #userPresent: _f$userPresent,
  };

  static EnrolledDevice _instantiate(DecodingData data) {
    return EnrolledDevice(
      deviceId: data.dec(_f$deviceId),
      userId: data.dec(_f$userId),
      phone: data.dec(_f$phone),
      ambient: data.dec(_f$ambient),
      userPresent: data.dec(_f$userPresent),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin EnrolledDeviceMappable {
  EnrolledDeviceCopyWith<EnrolledDevice, EnrolledDevice, EnrolledDevice>
      get copyWith =>
          _EnrolledDeviceCopyWithImpl<EnrolledDevice, EnrolledDevice>(
            this as EnrolledDevice,
            $identity,
            $identity,
          );
  @override
  bool operator ==(Object other) {
    return EnrolledDeviceMapper.ensureInitialized().equalsValue(
      this as EnrolledDevice,
      other,
    );
  }

  @override
  int get hashCode {
    return EnrolledDeviceMapper.ensureInitialized().hashValue(
      this as EnrolledDevice,
    );
  }
}

extension EnrolledDeviceValueCopy<$R, $Out>
    on ObjectCopyWith<$R, EnrolledDevice, $Out> {
  EnrolledDeviceCopyWith<$R, EnrolledDevice, $Out> get $asEnrolledDevice =>
      $base.as((v, t, t2) => _EnrolledDeviceCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class EnrolledDeviceCopyWith<$R, $In extends EnrolledDevice, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({
    String? deviceId,
    String? userId,
    String? phone,
    String? ambient,
    String? userPresent,
  });
  EnrolledDeviceCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _EnrolledDeviceCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, EnrolledDevice, $Out>
    implements EnrolledDeviceCopyWith<$R, EnrolledDevice, $Out> {
  _EnrolledDeviceCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<EnrolledDevice> $mapper =
      EnrolledDeviceMapper.ensureInitialized();
  @override
  $R call({
    String? deviceId,
    String? userId,
    String? phone,
    String? ambient,
    Object? userPresent = $none,
  }) =>
      $apply(
        FieldCopyWithData({
          if (deviceId != null) #deviceId: deviceId,
          if (userId != null) #userId: userId,
          if (phone != null) #phone: phone,
          if (ambient != null) #ambient: ambient,
          if (userPresent != $none) #userPresent: userPresent,
        }),
      );
  @override
  EnrolledDevice $make(CopyWithData data) => EnrolledDevice(
        deviceId: data.get(#deviceId, or: $value.deviceId),
        userId: data.get(#userId, or: $value.userId),
        phone: data.get(#phone, or: $value.phone),
        ambient: data.get(#ambient, or: $value.ambient),
        userPresent: data.get(#userPresent, or: $value.userPresent),
      );

  @override
  EnrolledDeviceCopyWith<$R2, EnrolledDevice, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _EnrolledDeviceCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class EnrolmentChallengesMapper extends ClassMapperBase<EnrolmentChallenges> {
  EnrolmentChallengesMapper._();

  static EnrolmentChallengesMapper? _instance;
  static EnrolmentChallengesMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = EnrolmentChallengesMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'EnrolmentChallenges';

  static String _$enrolmentId(EnrolmentChallenges v) => v.enrolmentId;
  static const Field<EnrolmentChallenges, String> _f$enrolmentId = Field(
    'enrolmentId',
    _$enrolmentId,
  );
  static String _$ambient(EnrolmentChallenges v) => v.ambient;
  static const Field<EnrolmentChallenges, String> _f$ambient = Field(
    'ambient',
    _$ambient,
  );
  static String? _$userPresent(EnrolmentChallenges v) => v.userPresent;
  static const Field<EnrolmentChallenges, String> _f$userPresent = Field(
    'userPresent',
    _$userPresent,
    opt: true,
  );

  @override
  final MappableFields<EnrolmentChallenges> fields = const {
    #enrolmentId: _f$enrolmentId,
    #ambient: _f$ambient,
    #userPresent: _f$userPresent,
  };

  static EnrolmentChallenges _instantiate(DecodingData data) {
    return EnrolmentChallenges(
      enrolmentId: data.dec(_f$enrolmentId),
      ambient: data.dec(_f$ambient),
      userPresent: data.dec(_f$userPresent),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin EnrolmentChallengesMappable {
  EnrolmentChallengesCopyWith<EnrolmentChallenges, EnrolmentChallenges,
      EnrolmentChallenges> get copyWith => _EnrolmentChallengesCopyWithImpl<
          EnrolmentChallenges, EnrolmentChallenges>(
      this as EnrolmentChallenges, $identity, $identity);
  @override
  bool operator ==(Object other) {
    return EnrolmentChallengesMapper.ensureInitialized().equalsValue(
      this as EnrolmentChallenges,
      other,
    );
  }

  @override
  int get hashCode {
    return EnrolmentChallengesMapper.ensureInitialized().hashValue(
      this as EnrolmentChallenges,
    );
  }
}

extension EnrolmentChallengesValueCopy<$R, $Out>
    on ObjectCopyWith<$R, EnrolmentChallenges, $Out> {
  EnrolmentChallengesCopyWith<$R, EnrolmentChallenges, $Out>
      get $asEnrolmentChallenges => $base.as(
            (v, t, t2) => _EnrolmentChallengesCopyWithImpl<$R, $Out>(v, t, t2),
          );
}

abstract class EnrolmentChallengesCopyWith<$R, $In extends EnrolmentChallenges,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  $R call({String? enrolmentId, String? ambient, String? userPresent});
  EnrolmentChallengesCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _EnrolmentChallengesCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, EnrolmentChallenges, $Out>
    implements EnrolmentChallengesCopyWith<$R, EnrolmentChallenges, $Out> {
  _EnrolmentChallengesCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<EnrolmentChallenges> $mapper =
      EnrolmentChallengesMapper.ensureInitialized();
  @override
  $R call({
    String? enrolmentId,
    String? ambient,
    Object? userPresent = $none,
  }) =>
      $apply(
        FieldCopyWithData({
          if (enrolmentId != null) #enrolmentId: enrolmentId,
          if (ambient != null) #ambient: ambient,
          if (userPresent != $none) #userPresent: userPresent,
        }),
      );
  @override
  EnrolmentChallenges $make(CopyWithData data) => EnrolmentChallenges(
        enrolmentId: data.get(#enrolmentId, or: $value.enrolmentId),
        ambient: data.get(#ambient, or: $value.ambient),
        userPresent: data.get(#userPresent, or: $value.userPresent),
      );

  @override
  EnrolmentChallengesCopyWith<$R2, EnrolmentChallenges, $Out2>
      $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
          _EnrolmentChallengesCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class OrderMapper extends ClassMapperBase<Order> {
  OrderMapper._();

  static OrderMapper? _instance;
  static OrderMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = OrderMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Order';

  static int _$id(Order v) => v.id;
  static const Field<Order, int> _f$id = Field('id', _$id);
  static String _$item(Order v) => v.item;
  static const Field<Order, String> _f$item = Field('item', _$item);
  static int _$quantity(Order v) => v.quantity;
  static const Field<Order, int> _f$quantity = Field('quantity', _$quantity);
  static String _$status(Order v) => v.status;
  static const Field<Order, String> _f$status = Field('status', _$status);

  @override
  final MappableFields<Order> fields = const {
    #id: _f$id,
    #item: _f$item,
    #quantity: _f$quantity,
    #status: _f$status,
  };

  static Order _instantiate(DecodingData data) {
    return Order(
      id: data.dec(_f$id),
      item: data.dec(_f$item),
      quantity: data.dec(_f$quantity),
      status: data.dec(_f$status),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin OrderMappable {
  OrderCopyWith<Order, Order, Order> get copyWith =>
      _OrderCopyWithImpl<Order, Order>(this as Order, $identity, $identity);
  @override
  bool operator ==(Object other) {
    return OrderMapper.ensureInitialized().equalsValue(this as Order, other);
  }

  @override
  int get hashCode {
    return OrderMapper.ensureInitialized().hashValue(this as Order);
  }
}

extension OrderValueCopy<$R, $Out> on ObjectCopyWith<$R, Order, $Out> {
  OrderCopyWith<$R, Order, $Out> get $asOrder =>
      $base.as((v, t, t2) => _OrderCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class OrderCopyWith<$R, $In extends Order, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({int? id, String? item, int? quantity, String? status});
  OrderCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _OrderCopyWithImpl<$R, $Out> extends ClassCopyWithBase<$R, Order, $Out>
    implements OrderCopyWith<$R, Order, $Out> {
  _OrderCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<Order> $mapper = OrderMapper.ensureInitialized();
  @override
  $R call({int? id, String? item, int? quantity, String? status}) => $apply(
        FieldCopyWithData({
          if (id != null) #id: id,
          if (item != null) #item: item,
          if (quantity != null) #quantity: quantity,
          if (status != null) #status: status,
        }),
      );
  @override
  Order $make(CopyWithData data) => Order(
        id: data.get(#id, or: $value.id),
        item: data.get(#item, or: $value.item),
        quantity: data.get(#quantity, or: $value.quantity),
        status: data.get(#status, or: $value.status),
      );

  @override
  OrderCopyWith<$R2, Order, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _OrderCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class OrderListMapper extends ClassMapperBase<OrderList> {
  OrderListMapper._();

  static OrderListMapper? _instance;
  static OrderListMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = OrderListMapper._());
      OrderMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'OrderList';

  static List<Order> _$orders(OrderList v) => v.orders;
  static const Field<OrderList, List<Order>> _f$orders = Field(
    'orders',
    _$orders,
  );

  @override
  final MappableFields<OrderList> fields = const {#orders: _f$orders};

  static OrderList _instantiate(DecodingData data) {
    return OrderList(orders: data.dec(_f$orders));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin OrderListMappable {
  OrderListCopyWith<OrderList, OrderList, OrderList> get copyWith =>
      _OrderListCopyWithImpl<OrderList, OrderList>(
        this as OrderList,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return OrderListMapper.ensureInitialized().equalsValue(
      this as OrderList,
      other,
    );
  }

  @override
  int get hashCode {
    return OrderListMapper.ensureInitialized().hashValue(this as OrderList);
  }
}

extension OrderListValueCopy<$R, $Out> on ObjectCopyWith<$R, OrderList, $Out> {
  OrderListCopyWith<$R, OrderList, $Out> get $asOrderList =>
      $base.as((v, t, t2) => _OrderListCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class OrderListCopyWith<$R, $In extends OrderList, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, Order, OrderCopyWith<$R, Order, Order>> get orders;
  $R call({List<Order>? orders});
  OrderListCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _OrderListCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, OrderList, $Out>
    implements OrderListCopyWith<$R, OrderList, $Out> {
  _OrderListCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<OrderList> $mapper =
      OrderListMapper.ensureInitialized();
  @override
  ListCopyWith<$R, Order, OrderCopyWith<$R, Order, Order>> get orders =>
      ListCopyWith(
        $value.orders,
        (v, t) => v.copyWith.$chain(t),
        (v) => call(orders: v),
      );
  @override
  $R call({List<Order>? orders}) =>
      $apply(FieldCopyWithData({if (orders != null) #orders: orders}));
  @override
  OrderList $make(CopyWithData data) =>
      OrderList(orders: data.get(#orders, or: $value.orders));

  @override
  OrderListCopyWith<$R2, OrderList, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _OrderListCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class RenewalChallengeMapper extends ClassMapperBase<RenewalChallenge> {
  RenewalChallengeMapper._();

  static RenewalChallengeMapper? _instance;
  static RenewalChallengeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RenewalChallengeMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'RenewalChallenge';

  static String _$challengeId(RenewalChallenge v) => v.challengeId;
  static const Field<RenewalChallenge, String> _f$challengeId = Field(
    'challengeId',
    _$challengeId,
  );
  static String _$challenge(RenewalChallenge v) => v.challenge;
  static const Field<RenewalChallenge, String> _f$challenge = Field(
    'challenge',
    _$challenge,
  );

  @override
  final MappableFields<RenewalChallenge> fields = const {
    #challengeId: _f$challengeId,
    #challenge: _f$challenge,
  };

  static RenewalChallenge _instantiate(DecodingData data) {
    return RenewalChallenge(
      challengeId: data.dec(_f$challengeId),
      challenge: data.dec(_f$challenge),
    );
  }

  @override
  final Function instantiate = _instantiate;
}

mixin RenewalChallengeMappable {
  RenewalChallengeCopyWith<RenewalChallenge, RenewalChallenge, RenewalChallenge>
      get copyWith =>
          _RenewalChallengeCopyWithImpl<RenewalChallenge, RenewalChallenge>(
            this as RenewalChallenge,
            $identity,
            $identity,
          );
  @override
  bool operator ==(Object other) {
    return RenewalChallengeMapper.ensureInitialized().equalsValue(
      this as RenewalChallenge,
      other,
    );
  }

  @override
  int get hashCode {
    return RenewalChallengeMapper.ensureInitialized().hashValue(
      this as RenewalChallenge,
    );
  }
}

extension RenewalChallengeValueCopy<$R, $Out>
    on ObjectCopyWith<$R, RenewalChallenge, $Out> {
  RenewalChallengeCopyWith<$R, RenewalChallenge, $Out>
      get $asRenewalChallenge => $base
          .as((v, t, t2) => _RenewalChallengeCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class RenewalChallengeCopyWith<$R, $In extends RenewalChallenge, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({String? challengeId, String? challenge});
  RenewalChallengeCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _RenewalChallengeCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, RenewalChallenge, $Out>
    implements RenewalChallengeCopyWith<$R, RenewalChallenge, $Out> {
  _RenewalChallengeCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<RenewalChallenge> $mapper =
      RenewalChallengeMapper.ensureInitialized();
  @override
  $R call({String? challengeId, String? challenge}) => $apply(
        FieldCopyWithData({
          if (challengeId != null) #challengeId: challengeId,
          if (challenge != null) #challenge: challenge,
        }),
      );
  @override
  RenewalChallenge $make(CopyWithData data) => RenewalChallenge(
        challengeId: data.get(#challengeId, or: $value.challengeId),
        challenge: data.get(#challenge, or: $value.challenge),
      );

  @override
  RenewalChallengeCopyWith<$R2, RenewalChallenge, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) =>
      _RenewalChallengeCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class RenewedMapper extends ClassMapperBase<Renewed> {
  RenewedMapper._();

  static RenewedMapper? _instance;
  static RenewedMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RenewedMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Renewed';

  static String _$attestation(Renewed v) => v.attestation;
  static const Field<Renewed, String> _f$attestation = Field(
    'attestation',
    _$attestation,
  );

  @override
  final MappableFields<Renewed> fields = const {#attestation: _f$attestation};

  static Renewed _instantiate(DecodingData data) {
    return Renewed(attestation: data.dec(_f$attestation));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin RenewedMappable {
  RenewedCopyWith<Renewed, Renewed, Renewed> get copyWith =>
      _RenewedCopyWithImpl<Renewed, Renewed>(
        this as Renewed,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return RenewedMapper.ensureInitialized().equalsValue(
      this as Renewed,
      other,
    );
  }

  @override
  int get hashCode {
    return RenewedMapper.ensureInitialized().hashValue(this as Renewed);
  }
}

extension RenewedValueCopy<$R, $Out> on ObjectCopyWith<$R, Renewed, $Out> {
  RenewedCopyWith<$R, Renewed, $Out> get $asRenewed =>
      $base.as((v, t, t2) => _RenewedCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class RenewedCopyWith<$R, $In extends Renewed, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({String? attestation});
  RenewedCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _RenewedCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, Renewed, $Out>
    implements RenewedCopyWith<$R, Renewed, $Out> {
  _RenewedCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<Renewed> $mapper =
      RenewedMapper.ensureInitialized();
  @override
  $R call({String? attestation}) => $apply(
        FieldCopyWithData({if (attestation != null) #attestation: attestation}),
      );
  @override
  Renewed $make(CopyWithData data) =>
      Renewed(attestation: data.get(#attestation, or: $value.attestation));

  @override
  RenewedCopyWith<$R2, Renewed, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _RenewedCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class RevokedMapper extends ClassMapperBase<Revoked> {
  RevokedMapper._();

  static RevokedMapper? _instance;
  static RevokedMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RevokedMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Revoked';

  static String _$deviceId(Revoked v) => v.deviceId;
  static const Field<Revoked, String> _f$deviceId = Field(
    'deviceId',
    _$deviceId,
  );

  @override
  final MappableFields<Revoked> fields = const {#deviceId: _f$deviceId};

  static Revoked _instantiate(DecodingData data) {
    return Revoked(deviceId: data.dec(_f$deviceId));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin RevokedMappable {
  RevokedCopyWith<Revoked, Revoked, Revoked> get copyWith =>
      _RevokedCopyWithImpl<Revoked, Revoked>(
        this as Revoked,
        $identity,
        $identity,
      );
  @override
  bool operator ==(Object other) {
    return RevokedMapper.ensureInitialized().equalsValue(
      this as Revoked,
      other,
    );
  }

  @override
  int get hashCode {
    return RevokedMapper.ensureInitialized().hashValue(this as Revoked);
  }
}

extension RevokedValueCopy<$R, $Out> on ObjectCopyWith<$R, Revoked, $Out> {
  RevokedCopyWith<$R, Revoked, $Out> get $asRevoked =>
      $base.as((v, t, t2) => _RevokedCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class RevokedCopyWith<$R, $In extends Revoked, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({String? deviceId});
  RevokedCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _RevokedCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, Revoked, $Out>
    implements RevokedCopyWith<$R, Revoked, $Out> {
  _RevokedCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<Revoked> $mapper =
      RevokedMapper.ensureInitialized();
  @override
  $R call({String? deviceId}) =>
      $apply(FieldCopyWithData({if (deviceId != null) #deviceId: deviceId}));
  @override
  Revoked $make(CopyWithData data) =>
      Revoked(deviceId: data.get(#deviceId, or: $value.deviceId));

  @override
  RevokedCopyWith<$R2, Revoked, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _RevokedCopyWithImpl<$R2, $Out2>($value, $cast, t);
}
