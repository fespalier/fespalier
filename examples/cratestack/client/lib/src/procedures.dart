import 'client.dart';
import 'package:cratestack_annotations/cratestack_annotations.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'runtime.dart';

part 'procedures.g.dart';
// issue #325: gated (unlike `part_file_name` above) — see
// `rest_procedures.dart.j2`'s identical guard for why.
part 'procedures.mapper.dart';
// issue #668 phase 2: same gate, same reason — see
// `rest_procedures.dart.j2`'s identical guard for why.
part 'procedures.builder.dart';

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class BeginEnrolmentProcedureArgs with BeginEnrolmentProcedureArgsMappable {
  const BeginEnrolmentProcedureArgs({
    required this.args,
  });

  final BeginEnrolmentArgs args;

  factory BeginEnrolmentProcedureArgs.fromWire(CratestackValueMap value) {
    return BeginEnrolmentProcedureArgs(
      args: BeginEnrolmentArgs.fromWire(cratestackAsValueMap(
          cratestackRequireWireValue(
              'BeginEnrolmentProcedureArgs', 'args', value['args']))),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'args': args.toWire(),
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class ConfirmEnrolmentProcedureArgs with ConfirmEnrolmentProcedureArgsMappable {
  const ConfirmEnrolmentProcedureArgs({
    required this.args,
  });

  final ConfirmEnrolmentArgs args;

  factory ConfirmEnrolmentProcedureArgs.fromWire(CratestackValueMap value) {
    return ConfirmEnrolmentProcedureArgs(
      args: ConfirmEnrolmentArgs.fromWire(cratestackAsValueMap(
          cratestackRequireWireValue(
              'ConfirmEnrolmentProcedureArgs', 'args', value['args']))),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'args': args.toWire(),
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class BeginRenewalProcedureArgs with BeginRenewalProcedureArgsMappable {
  const BeginRenewalProcedureArgs({
    required this.args,
  });

  final BeginRenewalArgs args;

  factory BeginRenewalProcedureArgs.fromWire(CratestackValueMap value) {
    return BeginRenewalProcedureArgs(
      args: BeginRenewalArgs.fromWire(cratestackAsValueMap(
          cratestackRequireWireValue(
              'BeginRenewalProcedureArgs', 'args', value['args']))),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'args': args.toWire(),
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class ConfirmRenewalProcedureArgs with ConfirmRenewalProcedureArgsMappable {
  const ConfirmRenewalProcedureArgs({
    required this.args,
  });

  final ConfirmRenewalArgs args;

  factory ConfirmRenewalProcedureArgs.fromWire(CratestackValueMap value) {
    return ConfirmRenewalProcedureArgs(
      args: ConfirmRenewalArgs.fromWire(cratestackAsValueMap(
          cratestackRequireWireValue(
              'ConfirmRenewalProcedureArgs', 'args', value['args']))),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'args': args.toWire(),
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class RevokeDeviceArgs with RevokeDeviceArgsMappable {
  const RevokeDeviceArgs({
    required this.args,
  });

  final RevokeArgs args;

  factory RevokeDeviceArgs.fromWire(CratestackValueMap value) {
    return RevokeDeviceArgs(
      args: RevokeArgs.fromWire(cratestackAsValueMap(cratestackRequireWireValue(
          'RevokeDeviceArgs', 'args', value['args']))),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'args': args.toWire(),
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class AccountArgs with AccountArgsMappable {
  const AccountArgs({
    required this.args,
  });

  final NoArgs args;

  factory AccountArgs.fromWire(CratestackValueMap value) {
    return AccountArgs(
      args: NoArgs.fromWire(cratestackAsValueMap(
          cratestackRequireWireValue('AccountArgs', 'args', value['args']))),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'args': args.toWire(),
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class ListOrdersProcedureArgs with ListOrdersProcedureArgsMappable {
  const ListOrdersProcedureArgs({
    required this.args,
  });

  final ListOrdersArgs args;

  factory ListOrdersProcedureArgs.fromWire(CratestackValueMap value) {
    return ListOrdersProcedureArgs(
      args: ListOrdersArgs.fromWire(cratestackAsValueMap(
          cratestackRequireWireValue(
              'ListOrdersProcedureArgs', 'args', value['args']))),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'args': args.toWire(),
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class GetOrderProcedureArgs with GetOrderProcedureArgsMappable {
  const GetOrderProcedureArgs({
    required this.args,
  });

  final GetOrderArgs args;

  factory GetOrderProcedureArgs.fromWire(CratestackValueMap value) {
    return GetOrderProcedureArgs(
      args: GetOrderArgs.fromWire(cratestackAsValueMap(
          cratestackRequireWireValue(
              'GetOrderProcedureArgs', 'args', value['args']))),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'args': args.toWire(),
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class PlaceOrderProcedureArgs with PlaceOrderProcedureArgsMappable {
  const PlaceOrderProcedureArgs({
    required this.args,
  });

  final PlaceOrderArgs args;

  factory PlaceOrderProcedureArgs.fromWire(CratestackValueMap value) {
    return PlaceOrderProcedureArgs(
      args: PlaceOrderArgs.fromWire(cratestackAsValueMap(
          cratestackRequireWireValue(
              'PlaceOrderProcedureArgs', 'args', value['args']))),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'args': args.toWire(),
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class PayOrderProcedureArgs with PayOrderProcedureArgsMappable {
  const PayOrderProcedureArgs({
    required this.args,
  });

  final PayOrderArgs args;

  factory PayOrderProcedureArgs.fromWire(CratestackValueMap value) {
    return PayOrderProcedureArgs(
      args: PayOrderArgs.fromWire(cratestackAsValueMap(
          cratestackRequireWireValue(
              'PayOrderProcedureArgs', 'args', value['args']))),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'args': args.toWire(),
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class Account with AccountMappable {
  const Account({
    required this.userId,
    required this.phone,
    required this.deviceId,
    required this.signedWith,
  });

  final String userId;
  final String phone;
  final String deviceId;
  final String signedWith;

  factory Account.fromWire(CratestackValueMap value) {
    return Account(
      userId: cratestackRequireWireValue('Account', 'userId', value['userId'])
          as String,
      phone: cratestackRequireWireValue('Account', 'phone', value['phone'])
          as String,
      deviceId:
          cratestackRequireWireValue('Account', 'deviceId', value['deviceId'])
              as String,
      signedWith: cratestackRequireWireValue(
          'Account', 'signedWith', value['signedWith']) as String,
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'userId': userId,
      'phone': phone,
      'deviceId': deviceId,
      'signedWith': signedWith,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class BeginEnrolmentArgs with BeginEnrolmentArgsMappable {
  const BeginEnrolmentArgs({
    required this.phone,
    required this.ambient,
    this.userPresent,
  });

  final String phone;
  final Jwk ambient;
  final Jwk? userPresent;

  factory BeginEnrolmentArgs.fromWire(CratestackValueMap value) {
    return BeginEnrolmentArgs(
      phone: cratestackRequireWireValue(
          'BeginEnrolmentArgs', 'phone', value['phone']) as String,
      ambient: Jwk.fromWire(cratestackAsValueMap(cratestackRequireWireValue(
          'BeginEnrolmentArgs', 'ambient', value['ambient']))),
      userPresent: value['userPresent'] == null
          ? null
          : Jwk.fromWire(cratestackAsValueMap(value['userPresent'])),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'phone': phone,
      'ambient': ambient.toWire(),
      'userPresent': userPresent?.toWire(),
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class BeginRenewalArgs with BeginRenewalArgsMappable {
  const BeginRenewalArgs({
    required this.deviceId,
    required this.role,
  });

  final String deviceId;
  final String role;

  factory BeginRenewalArgs.fromWire(CratestackValueMap value) {
    return BeginRenewalArgs(
      deviceId: cratestackRequireWireValue(
          'BeginRenewalArgs', 'deviceId', value['deviceId']) as String,
      role:
          cratestackRequireWireValue('BeginRenewalArgs', 'role', value['role'])
              as String,
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'deviceId': deviceId,
      'role': role,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class ConfirmEnrolmentArgs with ConfirmEnrolmentArgsMappable {
  const ConfirmEnrolmentArgs({
    required this.enrolmentId,
    required this.otp,
    required this.ambient,
    this.userPresent,
  });

  final String enrolmentId;
  final String otp;
  final String ambient;
  final String? userPresent;

  factory ConfirmEnrolmentArgs.fromWire(CratestackValueMap value) {
    return ConfirmEnrolmentArgs(
      enrolmentId: cratestackRequireWireValue(
              'ConfirmEnrolmentArgs', 'enrolmentId', value['enrolmentId'])
          as String,
      otp: cratestackRequireWireValue(
          'ConfirmEnrolmentArgs', 'otp', value['otp']) as String,
      ambient: cratestackRequireWireValue(
          'ConfirmEnrolmentArgs', 'ambient', value['ambient']) as String,
      userPresent:
          value['userPresent'] == null ? null : value['userPresent'] as String,
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'enrolmentId': enrolmentId,
      'otp': otp,
      'ambient': ambient,
      'userPresent': userPresent,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class ConfirmRenewalArgs with ConfirmRenewalArgsMappable {
  const ConfirmRenewalArgs({
    required this.challengeId,
    required this.signature,
  });

  final String challengeId;
  final String signature;

  factory ConfirmRenewalArgs.fromWire(CratestackValueMap value) {
    return ConfirmRenewalArgs(
      challengeId: cratestackRequireWireValue(
          'ConfirmRenewalArgs', 'challengeId', value['challengeId']) as String,
      signature: cratestackRequireWireValue(
          'ConfirmRenewalArgs', 'signature', value['signature']) as String,
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'challengeId': challengeId,
      'signature': signature,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class EnrolledDevice with EnrolledDeviceMappable {
  const EnrolledDevice({
    required this.deviceId,
    required this.userId,
    required this.phone,
    required this.ambient,
    this.userPresent,
  });

  final String deviceId;
  final String userId;
  final String phone;
  final String ambient;
  final String? userPresent;

  factory EnrolledDevice.fromWire(CratestackValueMap value) {
    return EnrolledDevice(
      deviceId: cratestackRequireWireValue(
          'EnrolledDevice', 'deviceId', value['deviceId']) as String,
      userId: cratestackRequireWireValue(
          'EnrolledDevice', 'userId', value['userId']) as String,
      phone:
          cratestackRequireWireValue('EnrolledDevice', 'phone', value['phone'])
              as String,
      ambient: cratestackRequireWireValue(
          'EnrolledDevice', 'ambient', value['ambient']) as String,
      userPresent:
          value['userPresent'] == null ? null : value['userPresent'] as String,
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'deviceId': deviceId,
      'userId': userId,
      'phone': phone,
      'ambient': ambient,
      'userPresent': userPresent,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class EnrolmentChallenges with EnrolmentChallengesMappable {
  const EnrolmentChallenges({
    required this.enrolmentId,
    required this.ambient,
    this.userPresent,
  });

  final String enrolmentId;
  final String ambient;
  final String? userPresent;

  factory EnrolmentChallenges.fromWire(CratestackValueMap value) {
    return EnrolmentChallenges(
      enrolmentId: cratestackRequireWireValue(
          'EnrolmentChallenges', 'enrolmentId', value['enrolmentId']) as String,
      ambient: cratestackRequireWireValue(
          'EnrolmentChallenges', 'ambient', value['ambient']) as String,
      userPresent:
          value['userPresent'] == null ? null : value['userPresent'] as String,
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'enrolmentId': enrolmentId,
      'ambient': ambient,
      'userPresent': userPresent,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class GetOrderArgs with GetOrderArgsMappable {
  const GetOrderArgs({
    required this.id,
  });

  final int id;

  factory GetOrderArgs.fromWire(CratestackValueMap value) {
    return GetOrderArgs(
      id: (cratestackRequireWireValue('GetOrderArgs', 'id', value['id']) as num)
          .toInt(),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'id': id,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class Jwk with JwkMappable {
  const Jwk({
    required this.kty,
    required this.crv,
    required this.x,
    required this.y,
  });

  final String kty;
  final String crv;
  final String x;
  final String y;

  factory Jwk.fromWire(CratestackValueMap value) {
    return Jwk(
      kty: cratestackRequireWireValue('Jwk', 'kty', value['kty']) as String,
      crv: cratestackRequireWireValue('Jwk', 'crv', value['crv']) as String,
      x: cratestackRequireWireValue('Jwk', 'x', value['x']) as String,
      y: cratestackRequireWireValue('Jwk', 'y', value['y']) as String,
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'kty': kty,
      'crv': crv,
      'x': x,
      'y': y,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class ListOrdersArgs with ListOrdersArgsMappable {
  const ListOrdersArgs({
    this.limit,
  });

  final int? limit;

  factory ListOrdersArgs.fromWire(CratestackValueMap value) {
    return ListOrdersArgs(
      limit: value['limit'] == null ? null : (value['limit'] as num).toInt(),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'limit': limit,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class NoArgs with NoArgsMappable {
  const NoArgs({
    this.unused,
  });

  final int? unused;

  factory NoArgs.fromWire(CratestackValueMap value) {
    return NoArgs(
      unused: value['unused'] == null ? null : (value['unused'] as num).toInt(),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'unused': unused,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class Order with OrderMappable {
  const Order({
    required this.id,
    required this.item,
    required this.quantity,
    required this.status,
  });

  final int id;
  final String item;
  final int quantity;
  final String status;

  factory Order.fromWire(CratestackValueMap value) {
    return Order(
      id: (cratestackRequireWireValue('Order', 'id', value['id']) as num)
          .toInt(),
      item:
          cratestackRequireWireValue('Order', 'item', value['item']) as String,
      quantity:
          (cratestackRequireWireValue('Order', 'quantity', value['quantity'])
                  as num)
              .toInt(),
      status: cratestackRequireWireValue('Order', 'status', value['status'])
          as String,
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'id': id,
      'item': item,
      'quantity': quantity,
      'status': status,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class OrderList with OrderListMappable {
  const OrderList({
    required this.orders,
  });

  final List<Order> orders;

  factory OrderList.fromWire(CratestackValueMap value) {
    return OrderList(
      orders: cratestackAsValueList(cratestackRequireWireValue(
              'OrderList', 'orders', value['orders']))
          .map((item) => Order.fromWire(cratestackAsValueMap(item)))
          .toList(growable: false),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'orders': orders.map((item) => item.toWire()).toList(growable: false),
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class PayOrderArgs with PayOrderArgsMappable {
  const PayOrderArgs({
    required this.id,
  });

  final int id;

  factory PayOrderArgs.fromWire(CratestackValueMap value) {
    return PayOrderArgs(
      id: (cratestackRequireWireValue('PayOrderArgs', 'id', value['id']) as num)
          .toInt(),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'id': id,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class PlaceOrderArgs with PlaceOrderArgsMappable {
  const PlaceOrderArgs({
    required this.item,
    required this.quantity,
  });

  final String item;
  final int quantity;

  factory PlaceOrderArgs.fromWire(CratestackValueMap value) {
    return PlaceOrderArgs(
      item: cratestackRequireWireValue('PlaceOrderArgs', 'item', value['item'])
          as String,
      quantity: (cratestackRequireWireValue(
              'PlaceOrderArgs', 'quantity', value['quantity']) as num)
          .toInt(),
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'item': item,
      'quantity': quantity,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class RenewalChallenge with RenewalChallengeMappable {
  const RenewalChallenge({
    required this.challengeId,
    required this.challenge,
  });

  final String challengeId;
  final String challenge;

  factory RenewalChallenge.fromWire(CratestackValueMap value) {
    return RenewalChallenge(
      challengeId: cratestackRequireWireValue(
          'RenewalChallenge', 'challengeId', value['challengeId']) as String,
      challenge: cratestackRequireWireValue(
          'RenewalChallenge', 'challenge', value['challenge']) as String,
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'challengeId': challengeId,
      'challenge': challenge,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class Renewed with RenewedMappable {
  const Renewed({
    required this.attestation,
  });

  final String attestation;

  factory Renewed.fromWire(CratestackValueMap value) {
    return Renewed(
      attestation: cratestackRequireWireValue(
          'Renewed', 'attestation', value['attestation']) as String,
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'attestation': attestation,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class RevokeArgs with RevokeArgsMappable {
  const RevokeArgs({
    required this.deviceId,
  });

  final String deviceId;

  factory RevokeArgs.fromWire(CratestackValueMap value) {
    return RevokeArgs(
      deviceId: cratestackRequireWireValue(
          'RevokeArgs', 'deviceId', value['deviceId']) as String,
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'deviceId': deviceId,
    };
  }
}

// issue #325: `@MappableClass()` (expanded by `dart_mappable_builder`
// alongside `riverpod_generator` in the same `build_runner` pass) gives
// this class real `operator ==`/`hashCode`/`copyWith` — every generated
// data class needs this under the `riverpod` preset because any of them
// can end up as a `@riverpod` family provider's argument type (see
// `EstimateFocusMinutesArgs` in `procedures.dart`), and riverpod's family
// cache dedupes provider instances by argument *value* equality, not
// identity. `generateMethods: GenerateMethods.equals | GenerateMethods.copy`
// deliberately does NOT ask for `encode`/`decode`/`stringify` — this
// generator already hand-rolls `fromWire`/`toWire` below (different
// method names, so there's no collision either way), and duplicating a
// second, unused `toMap`/`fromMap`/`toJson`/`fromJson` surface per class
// would be pure noise. Relation fields (e.g. `Task.board` -> `Board?`)
// get deep equality "for free": the referenced type is itself a
// `@MappableClass()`-annotated generated class in this same preset, so
// the field-by-field comparison this class's own `==` performs recurses
// into the related type's generated `==` rather than falling back to
// object identity; list-valued relations get the same element-wise
// (not `List.==`/identity) comparison automatically from
// `dart_mappable`'s own list handling.
@MappableClass(generateMethods: GenerateMethods.equals | GenerateMethods.copy)
@CratestackBuilder()
class Revoked with RevokedMappable {
  const Revoked({
    required this.deviceId,
  });

  final String deviceId;

  factory Revoked.fromWire(CratestackValueMap value) {
    return Revoked(
      deviceId:
          cratestackRequireWireValue('Revoked', 'deviceId', value['deviceId'])
              as String,
    );
  }

  CratestackValueMap toWire() {
    return <String, Object?>{
      'deviceId': deviceId,
    };
  }
}

class ProceduresApi {
  const ProceduresApi(this._client);

  final OrdersClientCratestackClient _client;

  Future<EnrolmentChallenges> beginEnrolment(
    BeginEnrolmentProcedureArgs args, {
    CratestackRpcCallOptions? options,
  }) async {
    final body = await _client.adapter.call(
      'procedure.beginEnrolment',
      args.toWire(),
      options: options,
    );
    return EnrolmentChallenges.fromWire(cratestackAsValueMap(
        cratestackRequireWireValue('Procedure', 'beginEnrolment', body)));
  }

  Future<EnrolledDevice> confirmEnrolment(
    ConfirmEnrolmentProcedureArgs args, {
    CratestackRpcCallOptions? options,
  }) async {
    final body = await _client.adapter.call(
      'procedure.confirmEnrolment',
      args.toWire(),
      options: options,
    );
    return EnrolledDevice.fromWire(cratestackAsValueMap(
        cratestackRequireWireValue('Procedure', 'confirmEnrolment', body)));
  }

  Future<RenewalChallenge> beginRenewal(
    BeginRenewalProcedureArgs args, {
    CratestackRpcCallOptions? options,
  }) async {
    final body = await _client.adapter.call(
      'procedure.beginRenewal',
      args.toWire(),
      options: options,
    );
    return RenewalChallenge.fromWire(cratestackAsValueMap(
        cratestackRequireWireValue('Procedure', 'beginRenewal', body)));
  }

  Future<Renewed> confirmRenewal(
    ConfirmRenewalProcedureArgs args, {
    CratestackRpcCallOptions? options,
  }) async {
    final body = await _client.adapter.call(
      'procedure.confirmRenewal',
      args.toWire(),
      options: options,
    );
    return Renewed.fromWire(cratestackAsValueMap(
        cratestackRequireWireValue('Procedure', 'confirmRenewal', body)));
  }

  Future<Revoked> revokeDevice(
    RevokeDeviceArgs args, {
    CratestackRpcCallOptions? options,
  }) async {
    final body = await _client.adapter.call(
      'procedure.revokeDevice',
      args.toWire(),
      options: options,
    );
    return Revoked.fromWire(cratestackAsValueMap(
        cratestackRequireWireValue('Procedure', 'revokeDevice', body)));
  }

  Future<Account> account(
    AccountArgs args, {
    CratestackRpcCallOptions? options,
  }) async {
    final body = await _client.adapter.call(
      'procedure.account',
      args.toWire(),
      options: options,
    );
    return Account.fromWire(cratestackAsValueMap(
        cratestackRequireWireValue('Procedure', 'account', body)));
  }

  Future<OrderList> listOrders(
    ListOrdersProcedureArgs args, {
    CratestackRpcCallOptions? options,
  }) async {
    final body = await _client.adapter.call(
      'procedure.listOrders',
      args.toWire(),
      options: options,
    );
    return OrderList.fromWire(cratestackAsValueMap(
        cratestackRequireWireValue('Procedure', 'listOrders', body)));
  }

  Future<Order> getOrder(
    GetOrderProcedureArgs args, {
    CratestackRpcCallOptions? options,
  }) async {
    final body = await _client.adapter.call(
      'procedure.getOrder',
      args.toWire(),
      options: options,
    );
    return Order.fromWire(cratestackAsValueMap(
        cratestackRequireWireValue('Procedure', 'getOrder', body)));
  }

  Future<Order> placeOrder(
    PlaceOrderProcedureArgs args, {
    CratestackRpcCallOptions? options,
  }) async {
    final body = await _client.adapter.call(
      'procedure.placeOrder',
      args.toWire(),
      options: options,
    );
    return Order.fromWire(cratestackAsValueMap(
        cratestackRequireWireValue('Procedure', 'placeOrder', body)));
  }

  Future<Order> payOrder(
    PayOrderProcedureArgs args, {
    CratestackRpcCallOptions? options,
  }) async {
    final body = await _client.adapter.call(
      'procedure.payOrder',
      args.toWire(),
      options: options,
    );
    return Order.fromWire(cratestackAsValueMap(
        cratestackRequireWireValue('Procedure', 'payOrder', body)));
  }
}

final ordersClientProceduresApiProvider = Provider<ProceduresApi>((ref) {
  return ref.watch(ordersClientClientProvider).procedures;
});

// Issue #302: one `@riverpod` provider per procedure, built by watching
// `ordersClientProceduresApiProvider` (declared above) — the
// same existing DI provider `ProceduresApi`'s own methods already go
// through. Query-kind procedures get a plain `Future`-returning function
// (mirrors a model's `get`/`list` providers); mutation-kind procedures
// get a controller class (mirrors a model's create/update/delete
// controllers) — see `model_providers.dart.j2`'s header comment for why
// writes aren't forced into the same shape as reads.
@riverpod
class BeginEnrolmentController extends _$BeginEnrolmentController {
  @override
  FutureOr<EnrolmentChallenges?> build() => null;

  Future<EnrolmentChallenges> beginEnrolment(
      BeginEnrolmentProcedureArgs args) async {
    state = const AsyncValue.loading();
    try {
      final result = await ref
          .read(ordersClientProceduresApiProvider)
          .beginEnrolment(args);
      state = AsyncValue.data(result);
      return result;
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
      rethrow;
    }
  }
}

@riverpod
class ConfirmEnrolmentController extends _$ConfirmEnrolmentController {
  @override
  FutureOr<EnrolledDevice?> build() => null;

  Future<EnrolledDevice> confirmEnrolment(
      ConfirmEnrolmentProcedureArgs args) async {
    state = const AsyncValue.loading();
    try {
      final result = await ref
          .read(ordersClientProceduresApiProvider)
          .confirmEnrolment(args);
      state = AsyncValue.data(result);
      return result;
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
      rethrow;
    }
  }
}

@riverpod
class BeginRenewalController extends _$BeginRenewalController {
  @override
  FutureOr<RenewalChallenge?> build() => null;

  Future<RenewalChallenge> beginRenewal(BeginRenewalProcedureArgs args) async {
    state = const AsyncValue.loading();
    try {
      final result =
          await ref.read(ordersClientProceduresApiProvider).beginRenewal(args);
      state = AsyncValue.data(result);
      return result;
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
      rethrow;
    }
  }
}

@riverpod
class ConfirmRenewalController extends _$ConfirmRenewalController {
  @override
  FutureOr<Renewed?> build() => null;

  Future<Renewed> confirmRenewal(ConfirmRenewalProcedureArgs args) async {
    state = const AsyncValue.loading();
    try {
      final result = await ref
          .read(ordersClientProceduresApiProvider)
          .confirmRenewal(args);
      state = AsyncValue.data(result);
      return result;
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
      rethrow;
    }
  }
}

@riverpod
class RevokeDeviceController extends _$RevokeDeviceController {
  @override
  FutureOr<Revoked?> build() => null;

  Future<Revoked> revokeDevice(RevokeDeviceArgs args) async {
    state = const AsyncValue.loading();
    try {
      final result =
          await ref.read(ordersClientProceduresApiProvider).revokeDevice(args);
      state = AsyncValue.data(result);
      return result;
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
      rethrow;
    }
  }
}

@riverpod
Future<Account> account(Ref ref, AccountArgs args) {
  return ref.watch(ordersClientProceduresApiProvider).account(args);
}

@riverpod
Future<OrderList> listOrders(Ref ref, ListOrdersProcedureArgs args) {
  return ref.watch(ordersClientProceduresApiProvider).listOrders(args);
}

@riverpod
Future<Order> getOrder(Ref ref, GetOrderProcedureArgs args) {
  return ref.watch(ordersClientProceduresApiProvider).getOrder(args);
}

@riverpod
class PlaceOrderController extends _$PlaceOrderController {
  @override
  FutureOr<Order?> build() => null;

  Future<Order> placeOrder(PlaceOrderProcedureArgs args) async {
    state = const AsyncValue.loading();
    try {
      final result =
          await ref.read(ordersClientProceduresApiProvider).placeOrder(args);
      state = AsyncValue.data(result);
      return result;
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
      rethrow;
    }
  }
}

@riverpod
class PayOrderController extends _$PayOrderController {
  @override
  FutureOr<Order?> build() => null;

  Future<Order> payOrder(PayOrderProcedureArgs args) async {
    state = const AsyncValue.loading();
    try {
      final result =
          await ref.read(ordersClientProceduresApiProvider).payOrder(args);
      state = AsyncValue.data(result);
      return result;
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
      rethrow;
    }
  }
}
