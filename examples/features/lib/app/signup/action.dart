import 'package:features/app.g.dart';
import 'package:features/signup.dart';
import 'package:fespalier/fespalier.dart';

/// The input of the action, and so the fields of the form that `signup/` asks over four pages.
typedef SignupFields = ({
  String name,
  bool business,
  String? company,
  String email,
  String? phone,
});

SignupFields form() =>
    (name: '', business: false, company: null, email: '', phone: null);

/// This `action.dart` is a section's (a `layout.dart` and no `page.dart` beside it), and `steps`
/// makes its form a multi-page one (since 0.11.0): each key is a child folder with a `page.dart`,
/// each value the fields of the input that step asks for, in order. A step with none is a page
/// of its own, here the review. Every field belongs to one step.
const steps = {
  'name': ['name', 'business'],
  'company': ['company'],
  'contact': ['email', 'phone'],
  'review': <String>[],
};

/// Optional: the steps that are left out for this input. `SignupStep` is the enum the generated
/// file declares for the steps. An individual has no company to give.
bool skip(SignupStep step, SignupFields input) =>
    step == SignupStep.company && !input.business;

/// Checked as the user goes (a step checks its own fields) and again for all of them at the end.
FieldErrors? validate(SignupFields input) => FieldErrors({
      if (input.name.trim().isEmpty) 'name': 'Enter your name',
      if (input.business && (input.company ?? '').trim().isEmpty)
        'company': 'Enter the company',
      if (!input.email.contains('@')) 'email': 'Enter an email',
    });

/// The server has the last word: an error it names is shown under the field, on the step that asks
/// for it.
Future<String> action(Ref ref, {required SignupFields input}) =>
    ref.read(signupServerProvider).signUp(
          name: input.name,
          email: input.email,
          company: input.business ? input.company : null,
        );
