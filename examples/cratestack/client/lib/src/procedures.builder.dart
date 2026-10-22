// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

part of 'procedures.dart';

// **************************************************************************
// CratestackBuilderGenerator
// **************************************************************************

class BeginEnrolmentProcedureArgsBuilder {
  BeginEnrolmentArgs? _args;
  bool _argsSet = false;

  BeginEnrolmentProcedureArgsBuilder args(BeginEnrolmentArgs value) {
    _args = value;
    _argsSet = true;
    return this;
  }

  BeginEnrolmentProcedureArgs build() {
    return BeginEnrolmentProcedureArgs(
      args: _argsSet
          ? (_args as BeginEnrolmentArgs)
          : (throw StateError(
              'BeginEnrolmentProcedureArgs.args is required but was not set')),
    );
  }
}

class ConfirmEnrolmentProcedureArgsBuilder {
  ConfirmEnrolmentArgs? _args;
  bool _argsSet = false;

  ConfirmEnrolmentProcedureArgsBuilder args(ConfirmEnrolmentArgs value) {
    _args = value;
    _argsSet = true;
    return this;
  }

  ConfirmEnrolmentProcedureArgs build() {
    return ConfirmEnrolmentProcedureArgs(
      args: _argsSet
          ? (_args as ConfirmEnrolmentArgs)
          : (throw StateError(
              'ConfirmEnrolmentProcedureArgs.args is required but was not set')),
    );
  }
}

class BeginRenewalProcedureArgsBuilder {
  BeginRenewalArgs? _args;
  bool _argsSet = false;

  BeginRenewalProcedureArgsBuilder args(BeginRenewalArgs value) {
    _args = value;
    _argsSet = true;
    return this;
  }

  BeginRenewalProcedureArgs build() {
    return BeginRenewalProcedureArgs(
      args: _argsSet
          ? (_args as BeginRenewalArgs)
          : (throw StateError(
              'BeginRenewalProcedureArgs.args is required but was not set')),
    );
  }
}

class ConfirmRenewalProcedureArgsBuilder {
  ConfirmRenewalArgs? _args;
  bool _argsSet = false;

  ConfirmRenewalProcedureArgsBuilder args(ConfirmRenewalArgs value) {
    _args = value;
    _argsSet = true;
    return this;
  }

  ConfirmRenewalProcedureArgs build() {
    return ConfirmRenewalProcedureArgs(
      args: _argsSet
          ? (_args as ConfirmRenewalArgs)
          : (throw StateError(
              'ConfirmRenewalProcedureArgs.args is required but was not set')),
    );
  }
}

class RevokeDeviceArgsBuilder {
  RevokeArgs? _args;
  bool _argsSet = false;

  RevokeDeviceArgsBuilder args(RevokeArgs value) {
    _args = value;
    _argsSet = true;
    return this;
  }

  RevokeDeviceArgs build() {
    return RevokeDeviceArgs(
      args: _argsSet
          ? (_args as RevokeArgs)
          : (throw StateError(
              'RevokeDeviceArgs.args is required but was not set')),
    );
  }
}

class AccountArgsBuilder {
  NoArgs? _args;
  bool _argsSet = false;

  AccountArgsBuilder args(NoArgs value) {
    _args = value;
    _argsSet = true;
    return this;
  }

  AccountArgs build() {
    return AccountArgs(
      args: _argsSet
          ? (_args as NoArgs)
          : (throw StateError('AccountArgs.args is required but was not set')),
    );
  }
}

class ListOrdersProcedureArgsBuilder {
  ListOrdersArgs? _args;
  bool _argsSet = false;

  ListOrdersProcedureArgsBuilder args(ListOrdersArgs value) {
    _args = value;
    _argsSet = true;
    return this;
  }

  ListOrdersProcedureArgs build() {
    return ListOrdersProcedureArgs(
      args: _argsSet
          ? (_args as ListOrdersArgs)
          : (throw StateError(
              'ListOrdersProcedureArgs.args is required but was not set')),
    );
  }
}

class GetOrderProcedureArgsBuilder {
  GetOrderArgs? _args;
  bool _argsSet = false;

  GetOrderProcedureArgsBuilder args(GetOrderArgs value) {
    _args = value;
    _argsSet = true;
    return this;
  }

  GetOrderProcedureArgs build() {
    return GetOrderProcedureArgs(
      args: _argsSet
          ? (_args as GetOrderArgs)
          : (throw StateError(
              'GetOrderProcedureArgs.args is required but was not set')),
    );
  }
}

class PlaceOrderProcedureArgsBuilder {
  PlaceOrderArgs? _args;
  bool _argsSet = false;

  PlaceOrderProcedureArgsBuilder args(PlaceOrderArgs value) {
    _args = value;
    _argsSet = true;
    return this;
  }

  PlaceOrderProcedureArgs build() {
    return PlaceOrderProcedureArgs(
      args: _argsSet
          ? (_args as PlaceOrderArgs)
          : (throw StateError(
              'PlaceOrderProcedureArgs.args is required but was not set')),
    );
  }
}

class PayOrderProcedureArgsBuilder {
  PayOrderArgs? _args;
  bool _argsSet = false;

  PayOrderProcedureArgsBuilder args(PayOrderArgs value) {
    _args = value;
    _argsSet = true;
    return this;
  }

  PayOrderProcedureArgs build() {
    return PayOrderProcedureArgs(
      args: _argsSet
          ? (_args as PayOrderArgs)
          : (throw StateError(
              'PayOrderProcedureArgs.args is required but was not set')),
    );
  }
}

class AccountBuilder {
  String? _userId;
  bool _userIdSet = false;
  String? _phone;
  bool _phoneSet = false;
  String? _deviceId;
  bool _deviceIdSet = false;
  String? _signedWith;
  bool _signedWithSet = false;

  AccountBuilder userId(String value) {
    _userId = value;
    _userIdSet = true;
    return this;
  }

  AccountBuilder phone(String value) {
    _phone = value;
    _phoneSet = true;
    return this;
  }

  AccountBuilder deviceId(String value) {
    _deviceId = value;
    _deviceIdSet = true;
    return this;
  }

  AccountBuilder signedWith(String value) {
    _signedWith = value;
    _signedWithSet = true;
    return this;
  }

  Account build() {
    return Account(
      userId: _userIdSet
          ? (_userId as String)
          : (throw StateError('Account.userId is required but was not set')),
      phone: _phoneSet
          ? (_phone as String)
          : (throw StateError('Account.phone is required but was not set')),
      deviceId: _deviceIdSet
          ? (_deviceId as String)
          : (throw StateError('Account.deviceId is required but was not set')),
      signedWith: _signedWithSet
          ? (_signedWith as String)
          : (throw StateError(
              'Account.signedWith is required but was not set')),
    );
  }
}

class BeginEnrolmentArgsBuilder {
  String? _phone;
  bool _phoneSet = false;
  Jwk? _ambient;
  bool _ambientSet = false;
  Jwk? _userPresent;

  BeginEnrolmentArgsBuilder phone(String value) {
    _phone = value;
    _phoneSet = true;
    return this;
  }

  BeginEnrolmentArgsBuilder ambient(Jwk value) {
    _ambient = value;
    _ambientSet = true;
    return this;
  }

  BeginEnrolmentArgsBuilder userPresent(Jwk? value) {
    _userPresent = value;
    return this;
  }

  BeginEnrolmentArgs build() {
    return BeginEnrolmentArgs(
      phone: _phoneSet
          ? (_phone as String)
          : (throw StateError(
              'BeginEnrolmentArgs.phone is required but was not set')),
      ambient: _ambientSet
          ? (_ambient as Jwk)
          : (throw StateError(
              'BeginEnrolmentArgs.ambient is required but was not set')),
      userPresent: _userPresent,
    );
  }
}

class BeginRenewalArgsBuilder {
  String? _deviceId;
  bool _deviceIdSet = false;
  String? _role;
  bool _roleSet = false;

  BeginRenewalArgsBuilder deviceId(String value) {
    _deviceId = value;
    _deviceIdSet = true;
    return this;
  }

  BeginRenewalArgsBuilder role(String value) {
    _role = value;
    _roleSet = true;
    return this;
  }

  BeginRenewalArgs build() {
    return BeginRenewalArgs(
      deviceId: _deviceIdSet
          ? (_deviceId as String)
          : (throw StateError(
              'BeginRenewalArgs.deviceId is required but was not set')),
      role: _roleSet
          ? (_role as String)
          : (throw StateError(
              'BeginRenewalArgs.role is required but was not set')),
    );
  }
}

class ConfirmEnrolmentArgsBuilder {
  String? _enrolmentId;
  bool _enrolmentIdSet = false;
  String? _otp;
  bool _otpSet = false;
  String? _ambient;
  bool _ambientSet = false;
  String? _userPresent;

  ConfirmEnrolmentArgsBuilder enrolmentId(String value) {
    _enrolmentId = value;
    _enrolmentIdSet = true;
    return this;
  }

  ConfirmEnrolmentArgsBuilder otp(String value) {
    _otp = value;
    _otpSet = true;
    return this;
  }

  ConfirmEnrolmentArgsBuilder ambient(String value) {
    _ambient = value;
    _ambientSet = true;
    return this;
  }

  ConfirmEnrolmentArgsBuilder userPresent(String? value) {
    _userPresent = value;
    return this;
  }

  ConfirmEnrolmentArgs build() {
    return ConfirmEnrolmentArgs(
      enrolmentId: _enrolmentIdSet
          ? (_enrolmentId as String)
          : (throw StateError(
              'ConfirmEnrolmentArgs.enrolmentId is required but was not set')),
      otp: _otpSet
          ? (_otp as String)
          : (throw StateError(
              'ConfirmEnrolmentArgs.otp is required but was not set')),
      ambient: _ambientSet
          ? (_ambient as String)
          : (throw StateError(
              'ConfirmEnrolmentArgs.ambient is required but was not set')),
      userPresent: _userPresent,
    );
  }
}

class ConfirmRenewalArgsBuilder {
  String? _challengeId;
  bool _challengeIdSet = false;
  String? _signature;
  bool _signatureSet = false;

  ConfirmRenewalArgsBuilder challengeId(String value) {
    _challengeId = value;
    _challengeIdSet = true;
    return this;
  }

  ConfirmRenewalArgsBuilder signature(String value) {
    _signature = value;
    _signatureSet = true;
    return this;
  }

  ConfirmRenewalArgs build() {
    return ConfirmRenewalArgs(
      challengeId: _challengeIdSet
          ? (_challengeId as String)
          : (throw StateError(
              'ConfirmRenewalArgs.challengeId is required but was not set')),
      signature: _signatureSet
          ? (_signature as String)
          : (throw StateError(
              'ConfirmRenewalArgs.signature is required but was not set')),
    );
  }
}

class EnrolledDeviceBuilder {
  String? _deviceId;
  bool _deviceIdSet = false;
  String? _userId;
  bool _userIdSet = false;
  String? _phone;
  bool _phoneSet = false;
  String? _ambient;
  bool _ambientSet = false;
  String? _userPresent;

  EnrolledDeviceBuilder deviceId(String value) {
    _deviceId = value;
    _deviceIdSet = true;
    return this;
  }

  EnrolledDeviceBuilder userId(String value) {
    _userId = value;
    _userIdSet = true;
    return this;
  }

  EnrolledDeviceBuilder phone(String value) {
    _phone = value;
    _phoneSet = true;
    return this;
  }

  EnrolledDeviceBuilder ambient(String value) {
    _ambient = value;
    _ambientSet = true;
    return this;
  }

  EnrolledDeviceBuilder userPresent(String? value) {
    _userPresent = value;
    return this;
  }

  EnrolledDevice build() {
    return EnrolledDevice(
      deviceId: _deviceIdSet
          ? (_deviceId as String)
          : (throw StateError(
              'EnrolledDevice.deviceId is required but was not set')),
      userId: _userIdSet
          ? (_userId as String)
          : (throw StateError(
              'EnrolledDevice.userId is required but was not set')),
      phone: _phoneSet
          ? (_phone as String)
          : (throw StateError(
              'EnrolledDevice.phone is required but was not set')),
      ambient: _ambientSet
          ? (_ambient as String)
          : (throw StateError(
              'EnrolledDevice.ambient is required but was not set')),
      userPresent: _userPresent,
    );
  }
}

class EnrolmentChallengesBuilder {
  String? _enrolmentId;
  bool _enrolmentIdSet = false;
  String? _ambient;
  bool _ambientSet = false;
  String? _userPresent;

  EnrolmentChallengesBuilder enrolmentId(String value) {
    _enrolmentId = value;
    _enrolmentIdSet = true;
    return this;
  }

  EnrolmentChallengesBuilder ambient(String value) {
    _ambient = value;
    _ambientSet = true;
    return this;
  }

  EnrolmentChallengesBuilder userPresent(String? value) {
    _userPresent = value;
    return this;
  }

  EnrolmentChallenges build() {
    return EnrolmentChallenges(
      enrolmentId: _enrolmentIdSet
          ? (_enrolmentId as String)
          : (throw StateError(
              'EnrolmentChallenges.enrolmentId is required but was not set')),
      ambient: _ambientSet
          ? (_ambient as String)
          : (throw StateError(
              'EnrolmentChallenges.ambient is required but was not set')),
      userPresent: _userPresent,
    );
  }
}

class GetOrderArgsBuilder {
  int? _id;
  bool _idSet = false;

  GetOrderArgsBuilder id(int value) {
    _id = value;
    _idSet = true;
    return this;
  }

  GetOrderArgs build() {
    return GetOrderArgs(
      id: _idSet
          ? (_id as int)
          : (throw StateError('GetOrderArgs.id is required but was not set')),
    );
  }
}

class JwkBuilder {
  String? _kty;
  bool _ktySet = false;
  String? _crv;
  bool _crvSet = false;
  String? _x;
  bool _xSet = false;
  String? _y;
  bool _ySet = false;

  JwkBuilder kty(String value) {
    _kty = value;
    _ktySet = true;
    return this;
  }

  JwkBuilder crv(String value) {
    _crv = value;
    _crvSet = true;
    return this;
  }

  JwkBuilder x(String value) {
    _x = value;
    _xSet = true;
    return this;
  }

  JwkBuilder y(String value) {
    _y = value;
    _ySet = true;
    return this;
  }

  Jwk build() {
    return Jwk(
      kty: _ktySet
          ? (_kty as String)
          : (throw StateError('Jwk.kty is required but was not set')),
      crv: _crvSet
          ? (_crv as String)
          : (throw StateError('Jwk.crv is required but was not set')),
      x: _xSet
          ? (_x as String)
          : (throw StateError('Jwk.x is required but was not set')),
      y: _ySet
          ? (_y as String)
          : (throw StateError('Jwk.y is required but was not set')),
    );
  }
}

class ListOrdersArgsBuilder {
  int? _limit;

  ListOrdersArgsBuilder limit(int? value) {
    _limit = value;
    return this;
  }

  ListOrdersArgs build() {
    return ListOrdersArgs(
      limit: _limit,
    );
  }
}

class NoArgsBuilder {
  int? _unused;

  NoArgsBuilder unused(int? value) {
    _unused = value;
    return this;
  }

  NoArgs build() {
    return NoArgs(
      unused: _unused,
    );
  }
}

class OrderBuilder {
  int? _id;
  bool _idSet = false;
  String? _item;
  bool _itemSet = false;
  int? _quantity;
  bool _quantitySet = false;
  String? _status;
  bool _statusSet = false;

  OrderBuilder id(int value) {
    _id = value;
    _idSet = true;
    return this;
  }

  OrderBuilder item(String value) {
    _item = value;
    _itemSet = true;
    return this;
  }

  OrderBuilder quantity(int value) {
    _quantity = value;
    _quantitySet = true;
    return this;
  }

  OrderBuilder status(String value) {
    _status = value;
    _statusSet = true;
    return this;
  }

  Order build() {
    return Order(
      id: _idSet
          ? (_id as int)
          : (throw StateError('Order.id is required but was not set')),
      item: _itemSet
          ? (_item as String)
          : (throw StateError('Order.item is required but was not set')),
      quantity: _quantitySet
          ? (_quantity as int)
          : (throw StateError('Order.quantity is required but was not set')),
      status: _statusSet
          ? (_status as String)
          : (throw StateError('Order.status is required but was not set')),
    );
  }
}

class OrderListBuilder {
  List<Order>? _orders;

  OrderListBuilder orders(List<Order> value) {
    _orders = value;
    return this;
  }

  OrderListBuilder addOrders(Order value) {
    (_orders = <Order>[...?_orders]).add(value);
    return this;
  }

  OrderList build() {
    return OrderList(
      orders: _orders ?? <Order>[],
    );
  }
}

class PayOrderArgsBuilder {
  int? _id;
  bool _idSet = false;

  PayOrderArgsBuilder id(int value) {
    _id = value;
    _idSet = true;
    return this;
  }

  PayOrderArgs build() {
    return PayOrderArgs(
      id: _idSet
          ? (_id as int)
          : (throw StateError('PayOrderArgs.id is required but was not set')),
    );
  }
}

class PlaceOrderArgsBuilder {
  String? _item;
  bool _itemSet = false;
  int? _quantity;
  bool _quantitySet = false;

  PlaceOrderArgsBuilder item(String value) {
    _item = value;
    _itemSet = true;
    return this;
  }

  PlaceOrderArgsBuilder quantity(int value) {
    _quantity = value;
    _quantitySet = true;
    return this;
  }

  PlaceOrderArgs build() {
    return PlaceOrderArgs(
      item: _itemSet
          ? (_item as String)
          : (throw StateError(
              'PlaceOrderArgs.item is required but was not set')),
      quantity: _quantitySet
          ? (_quantity as int)
          : (throw StateError(
              'PlaceOrderArgs.quantity is required but was not set')),
    );
  }
}

class RenewalChallengeBuilder {
  String? _challengeId;
  bool _challengeIdSet = false;
  String? _challenge;
  bool _challengeSet = false;

  RenewalChallengeBuilder challengeId(String value) {
    _challengeId = value;
    _challengeIdSet = true;
    return this;
  }

  RenewalChallengeBuilder challenge(String value) {
    _challenge = value;
    _challengeSet = true;
    return this;
  }

  RenewalChallenge build() {
    return RenewalChallenge(
      challengeId: _challengeIdSet
          ? (_challengeId as String)
          : (throw StateError(
              'RenewalChallenge.challengeId is required but was not set')),
      challenge: _challengeSet
          ? (_challenge as String)
          : (throw StateError(
              'RenewalChallenge.challenge is required but was not set')),
    );
  }
}

class RenewedBuilder {
  String? _attestation;
  bool _attestationSet = false;

  RenewedBuilder attestation(String value) {
    _attestation = value;
    _attestationSet = true;
    return this;
  }

  Renewed build() {
    return Renewed(
      attestation: _attestationSet
          ? (_attestation as String)
          : (throw StateError(
              'Renewed.attestation is required but was not set')),
    );
  }
}

class RevokeArgsBuilder {
  String? _deviceId;
  bool _deviceIdSet = false;

  RevokeArgsBuilder deviceId(String value) {
    _deviceId = value;
    _deviceIdSet = true;
    return this;
  }

  RevokeArgs build() {
    return RevokeArgs(
      deviceId: _deviceIdSet
          ? (_deviceId as String)
          : (throw StateError(
              'RevokeArgs.deviceId is required but was not set')),
    );
  }
}

class RevokedBuilder {
  String? _deviceId;
  bool _deviceIdSet = false;

  RevokedBuilder deviceId(String value) {
    _deviceId = value;
    _deviceIdSet = true;
    return this;
  }

  Revoked build() {
    return Revoked(
      deviceId: _deviceIdSet
          ? (_deviceId as String)
          : (throw StateError('Revoked.deviceId is required but was not set')),
    );
  }
}
