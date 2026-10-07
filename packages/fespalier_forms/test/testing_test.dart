import 'package:fespalier/fespalier.dart';
import 'package:fespalier_forms/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('isFieldErrors matches the fields and the message', () {
    const errors = FieldErrors({'name': 'Taken'}, message: 'Could not save');
    expect(errors, isFieldErrors({'name': 'Taken'}, message: 'Could not save'));
    expect(errors, isNot(isFieldErrors({'name': 'Taken'})));
    expect(
      errors,
      isNot(isFieldErrors({'age': 'Taken'}, message: 'Could not save')),
    );
    expect(Exception('x'), isNot(isFieldErrors({})));
  });

  test('it reads through throwsA', () {
    Never fail() => throw const FieldErrors({'name': 'Taken'});
    expect(fail, throwsA(isFieldErrors({'name': 'Taken'})));
  });
}
