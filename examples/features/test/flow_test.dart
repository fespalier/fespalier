// A multi-page form (since 0.11.0): `signup/` is a section whose action.dart has `const steps`.
// The four steps share one form and one draft, and the question about unsaved changes is asked
// once, when the flow is left.
import 'package:features/app.g.dart';
import 'package:features/signup.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_forms/fespalier_forms.dart';
import 'package:fespalier_forms/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const id = 'signup/action.dart#action';
const shape =
    'name:String,business:bool,company:String?,email:String,phone:String?';

void main() {
  late SignupServer server;
  late MemoryDataStorage storage;
  late GoRouter router;

  setUp(() {
    server = SignupServer();
    storage = MemoryDataStorage();
  });

  Future<ProviderContainer> open(
    WidgetTester tester, {
    String at = '/signup/name',
    List<Override> overrides = const [],
  }) async {
    router = AppRoutes.router(initialLocation: '/profile');
    final container = await pumpRouter(
      tester,
      router,
      overrides: [
        signupServerProvider.overrideWithValue(server),
        formDraftStorage.overrideWithValue(storage),
        ...overrides,
      ],
    );
    router.go(at);
    await tester.pumpAndSettle();
    return container;
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  Future<void> type(WidgetTester tester, String label, String text) async {
    await tester.enterText(field(label), text);
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  Future<void> toReview(WidgetTester tester) async {
    await type(tester, 'Name', 'Ann');
    await tap(tester, 'Next');
    await type(tester, 'Email', 'ann@x.org');
    await tap(tester, 'Next');
  }

  testWidgets('next checks the fields of its own step, and the steps shown', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Step 1 of 3'), findsOneWidget);
    await tap(tester, 'Next');
    expect(find.text('Enter your name'), findsOneWidget);
    expect(find.text('Enter an email'), findsNothing);
    expectStep(tester, SignupStep.name);
    await type(tester, 'Name', 'Ann');
    await tap(tester, 'Next');
    // An individual has no company step.
    expectStep(tester, SignupStep.contact);
    expect(find.text('Step 2 of 3'), findsOneWidget);
  });

  testWidgets('a business has a company step, and back keeps what was typed', (
    tester,
  ) async {
    await open(tester);
    await type(tester, 'Name', 'Acme Ltd');
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(find.text('Step 1 of 4'), findsOneWidget);
    await tap(tester, 'Next');
    expectStep(tester, SignupStep.company);
    await tap(tester, 'Next');
    expect(find.text('Enter the company'), findsOneWidget);
    await type(tester, 'Company', 'Acme');
    await tap(tester, 'Next');
    expectStep(tester, SignupStep.contact);
    await tap(tester, 'Back');
    expectStep(tester, SignupStep.company);
    expect(find.text('Acme'), findsOneWidget);
  });

  testWidgets('a step is edited from the review with goTo', (tester) async {
    await open(tester);
    await toReview(tester);
    expectStep(tester, SignupStep.review);
    await tap(tester, 'Edit name');
    expectStep(tester, SignupStep.name);
    await type(tester, 'Name', 'Anna');
    await tap(tester, 'Next');
    expectStep(tester, SignupStep.contact);
  });

  testWidgets('the server\'s error on a field goes to the step that owns it', (
    tester,
  ) async {
    await open(tester);
    await toReview(tester);
    server.errors = {'email': 'Already used'};
    await tap(tester, 'Create account');
    expect(server.sent, ['Ann <ann@x.org>']);
    expectStep(tester, SignupStep.contact);
    expect(find.text('Already used'), findsOneWidget);
  });

  testWidgets('a successful sign-up shows the account and keeps no draft', (
    tester,
  ) async {
    final container = await open(tester);
    await toReview(tester);
    await tap(tester, 'Create account');
    expect(find.text('Created account-1'), findsOneWidget);
    expect(await readFormDraft(container, id: id, shape: shape), isNull);
  });

  testWidgets('a restart finds the fields and the steps done', (tester) async {
    final container = await open(tester);
    await type(tester, 'Name', 'Ann');
    await tap(tester, 'Next');
    await type(tester, 'Email', 'ann@x');
    router.go('/profile');
    await tester.pumpAndSettle();
    // Leaving asked: keep it as a draft.
    await tap(tester, 'Keep as draft');
    expect(await readFormDraftSteps(container, id: id, shape: shape), [
      'name',
    ]);
    await tester.pumpWidget(const SizedBox());
    await open(tester, at: '/signup/review');
    // The link is past what was done: the flow opens at the first step not done.
    expectStep(tester, SignupStep.contact);
    expect(find.text('ann@x'), findsOneWidget);
  });

  testWidgets('a link past what was done opens the first step not done', (
    tester,
  ) async {
    await open(tester, at: '/signup/review');
    expectStep(tester, SignupStep.name);
  });

  testWidgets('leaving is asked once, when the flow is left', (tester) async {
    await open(tester);
    await type(tester, 'Name', 'Ann');
    await tap(tester, 'Next');
    expect(find.text('Discard your changes?'), findsNothing);
    router.go('/profile');
    await tester.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsOneWidget);
    await tap(tester, 'Keep editing');
    expectStep(tester, SignupStep.contact);
    await type(tester, 'Email', 'ann@x.org');
    await tap(tester, 'Next');
    expectStep(tester, SignupStep.review);
    expect(find.text('Discard your changes?'), findsNothing);
  });

  testWidgets('the system back goes to the previous step', (tester) async {
    await open(tester);
    await toReview(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expectStep(tester, SignupStep.contact);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expectStep(tester, SignupStep.name);
  });
}
