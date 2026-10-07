// ignore_for_file: prefer_function_declarations_over_variables
// (the generated file writes its route members as closures, so these do too)

// Multi-page forms (since 0.11.0): a section's steps share one form and one draft. What `fsp`
// generates for a flow section (the step enum, a `FlowSpec` with `useFlow`, `flowOf` and
// `resume`, and a step's `GoRoute` with `within:`) is written by hand under "what fsp would
// generate", over a section with four steps, `company` skipped for an individual.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/persist.dart';
import 'package:fespalier/testing.dart' show Override;
import 'package:fespalier_forms/fespalier_forms.dart';
import 'package:fespalier_forms/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ---- what the app writes ---------------------------------------------------------------

typedef SignupFields = ({
  String name,
  bool business,
  String? company,
  String email,
  String? phone,
});

SignupFields form() =>
    (name: '', business: false, company: null, email: '', phone: null);

/// What the server was sent, and what it says to the next one.
final List<SignupFields> sent = [];
Map<String, String>? serverErrors;
String? serverMessage;
Completer<void>? gate;

Future<String> action(Ref ref, {required SignupFields input}) async {
  sent.add(input);
  if (gate case final g?) await g.future;
  if (serverErrors case final e?) {
    throw FieldErrors(e, message: serverMessage);
  }
  return input.name;
}

FieldErrors? validate(SignupFields input) => FieldErrors({
  if (input.name.isEmpty) 'name': 'Enter your name',
  if (input.business && (input.company ?? '').isEmpty)
    'company': 'Enter the company',
  if (!input.email.contains('@')) 'email': 'Enter an email',
});

bool skip(SignupStep step, SignupFields input) =>
    step == SignupStep.company && !input.business;

// ---- what fsp would generate ---------------------------------------------------------------

enum SignupStep { name, company, contact, review }

final _action = actionProvider<SignupFields, String>(
  (Ref ref, SignupFields input) => action(ref, input: input),
  invalidates: () => const <ProviderListenable<AsyncValue<Object?>>>[],
  validate: validate,
  site: 'a1_0',
);

class SignupNameRoute extends TypedLocation {
  const SignupNameRoute();
  @override
  String get location => '/signup/name';
}

class SignupCompanyRoute extends TypedLocation {
  const SignupCompanyRoute();
  @override
  String get location => '/signup/company';
}

class SignupContactRoute extends TypedLocation {
  const SignupContactRoute();
  @override
  String get location => '/signup/contact';
}

class SignupReviewRoute extends TypedLocation {
  const SignupReviewRoute();
  @override
  String get location => '/signup/review';
}

abstract final class SignupSection {
  static final action = _action;

  static final _flow = FlowSpec(
    id: 'signup/action.dart#action',
    shape:
        'name:String,business:bool,company:String?,email:String,phone:String?',
    steps: SignupStep.values,
    routes: {
      SignupStep.name: const SignupNameRoute(),
      SignupStep.company: const SignupCompanyRoute(),
      SignupStep.contact: const SignupContactRoute(),
      SignupStep.review: const SignupReviewRoute(),
    },
    owners: const {
      'name': SignupStep.name,
      'business': SignupStep.name,
      'company': SignupStep.company,
      'email': SignupStep.contact,
      'phone': SignupStep.contact,
    },
    skip: skip,
    initial: form,
    fields: (ActionFormFields<SignupFields> f) => (
      name: f.text('name', (v) => v.name, FieldCodec.text),
      business: f.value(
        'business',
        (v) => v.business,
        draft: DraftCodec.boolean,
      ),
      company: f.text('company', (v) => v.company, FieldCodec.optionalText),
      email: f.text('email', (v) => v.email, FieldCodec.text),
      phone: f.text('phone', (v) => v.phone, FieldCodec.optionalText),
    ),
    input: (f) => (
      name: f.name.value,
      business: f.business.value,
      company: f.company.value,
      email: f.email.value,
      phone: f.phone.value,
    ),
    validate: validate,
  );

  static final useFlow =
      (
        WidgetRef ref, {
        ActionFormValidation validation = ActionFormValidation.afterSubmit,
        FormDraft? draft = const FormDraft(),
        ActionFormMessages messages = const ActionFormMessages(),
      }) => _flow.use(
        ref,
        action,
        validation: validation,
        draft: draft,
        messages: messages,
      );

  static final flowOf = (BuildContext context) => _flow.of(context);

  static GuardResult resume(Ref ref, {required Uri uri}) =>
      _flow.resume(ref, uri: uri);
}

typedef SignupFlowFields = ({
  ActionTextField<String> name,
  ActionField<bool> business,
  ActionTextField<String?> company,
  ActionTextField<String> email,
  ActionTextField<String?> phone,
});

/// What `flowOf` gives a step page.
typedef SignupFlow =
    FormFlow<SignupFields, Object?, SignupStep, SignupFlowFields>;

// ---- the files of the section ---------------------------------------------------------------

/// Set by a test: the draft the layout's `useFlow` is given.
FormDraft? draftOf = const FormDraft();

/// The `leave.dart` of the section: `leaveIfClean` and nothing else.
final List<Object?> asked = [];

class SignupLayout extends HookConsumerWidget {
  const SignupLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = SignupSection.useFlow(ref, draft: draftOf);
    return FormFlowScope(
      flow: flow,
      child: Scaffold(
        body: Column(
          children: [
            Text(
              'progress ${flow.progress.toStringAsFixed(2)} '
              '(${flow.index + 1} of ${flow.count})',
              key: const Key('progress'),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class NamePage extends StatelessWidget {
  const NamePage({super.key});

  @override
  Widget build(BuildContext context) {
    final flow = SignupSection.flowOf(context);
    final f = flow.fields;
    return Column(
      children: [
        TextField(
          key: const Key('name'),
          controller: f.name.controller,
          decoration: InputDecoration(errorText: f.name.error),
        ),
        Checkbox(
          key: const Key('business'),
          value: f.business.value,
          onChanged: f.business.didChange,
        ),
        FilledButton(
          onPressed: () => flow.next(context),
          child: const Text('Next'),
        ),
      ],
    );
  }
}

class CompanyPage extends StatelessWidget {
  const CompanyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final flow = SignupSection.flowOf(context);
    final f = flow.fields;
    return Column(
      children: [
        TextField(
          key: const Key('company'),
          controller: f.company.controller,
          decoration: InputDecoration(errorText: f.company.error),
        ),
        FilledButton(
          onPressed: () => flow.next(context),
          child: const Text('Next'),
        ),
      ],
    );
  }
}

class ContactPage extends StatelessWidget {
  const ContactPage({super.key});

  @override
  Widget build(BuildContext context) {
    final flow = SignupSection.flowOf(context);
    final f = flow.fields;
    return Column(
      children: [
        TextField(
          key: const Key('email'),
          controller: f.email.controller,
          decoration: InputDecoration(errorText: f.email.error),
        ),
        TextField(
          key: const Key('phone'),
          controller: f.phone.controller,
          decoration: InputDecoration(errorText: f.phone.error),
        ),
        FilledButton(
          onPressed: () => flow.next(context),
          child: const Text('Next'),
        ),
      ],
    );
  }
}

class ReviewPage extends StatelessWidget {
  const ReviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final flow = SignupSection.flowOf(context);
    return Column(
      children: [
        Text('review ${flow.fields.name.value} ${flow.fields.email.value}'),
        if (flow.error != null) Text('error: ${flow.error}'),
        if (flow.canGoTo(SignupStep.name))
          TextButton(
            onPressed: () => flow.goTo(context, SignupStep.name),
            child: const Text('Edit name'),
          ),
        FilledButton(
          onPressed: flow.isPending ? null : flow.submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// A step's `GoRoute`, as the generator writes it: the section's guard (`resume`), its `leave()`
/// as `onExit` with `within:`, and the page in `leaveScope` and `flowStep`.
GoRoute step(String path, Widget page) => GoRoute(
  path: path,
  redirect: (context, state) => refGuard(
    context,
    'signup/guard.dart',
    (ref) => SignupSection.resume(ref, uri: state.uri),
  ),
  onExit: (context, state) =>
      leaveExit(context, state, 'signup/leave.dart', (ref, pageLeave) {
        final result = leaveIfClean(context, ref, pageLeave);
        asked.add(result);
        return result;
      }, within: '/signup'),
  pageBuilder: (context, state) => MaterialPage<void>(
    key: state.pageKey,
    child: leaveScope(state, flowStep(page)),
  ),
);

GoRouter makeRouter(String initial) => GoRouter(
  initialLocation: initial,
  routes: [
    GoRoute(
      path: '/',
      pageBuilder: (context, state) => MaterialPage<void>(
        key: state.pageKey,
        child: const Scaffold(body: Text('Home')),
      ),
    ),
    ShellRoute(
      builder: (context, state, child) => SignupLayout(child: child),
      routes: [
        step('/signup/name', const NamePage()),
        step('/signup/company', const CompanyPage()),
        step('/signup/contact', const ContactPage()),
        step('/signup/review', const ReviewPage()),
      ],
    ),
  ],
);

// ---- the tests -------------------------------------------------------------------------------

late GoRouter router;

/// A container on the same storage, for reads after the app's own is gone.
ProviderContainer reader() {
  final c = ProviderContainer(
    overrides: [formDraftStorage.overrideWithValue(storage)],
  );
  addTearDown(c.dispose);
  return c;
}

late MemoryDataStorage storage;

const id = 'signup/action.dart#action';
const shape =
    'name:String,business:bool,company:String?,email:String,phone:String?';

Future<ProviderContainer> boot(
  WidgetTester tester, {
  String at = '/signup/name',
  List<Override> overrides = const [],
  FutureOr<Storage<String, String>?>? withStorage,
}) async {
  router = makeRouter(at);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        formDraftStorage.overrideWithValue(withStorage ?? storage),
        ...overrides,
      ],
      retry: (_, _) => null,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(SignupLayout)));
}

Future<void> typeInto(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

/// The flow, read from a step page.
SignupFlow flowOnScreen(WidgetTester tester) =>
    SignupSection.flowOf(tester.element(find.byType(Scaffold).last));

/// Android's back. [wait] is false when it opens a question that the test answers afterwards.
Future<void> systemBack(WidgetTester tester, {bool wait = true}) async {
  if (wait) {
    await tester.binding.handlePopRoute();
  } else {
    unawaited(tester.binding.handlePopRoute());
  }
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    storage = MemoryDataStorage();
    draftOf = const FormDraft();
    sent.clear();
    asked.clear();
    serverErrors = null;
    serverMessage = null;
    gate = null;
  });

  group('next', () {
    testWidgets('checks the fields of the step alone', (tester) async {
      await boot(tester);
      // The email of a later step is empty: not this step's business.
      await tapText(tester, 'Next');
      expect(find.text('Enter your name'), findsOneWidget);
      expect(find.text('Enter an email'), findsNothing);
      expectStep(tester, SignupStep.name);
      await typeInto(tester, 'name', 'Ann');
      await tapText(tester, 'Next');
      expectStep(tester, SignupStep.contact);
      expect(find.text('Enter your name'), findsNothing);
      // Its own errors show once it was tried, not before.
      expect(find.text('Enter an email'), findsNothing);
      await tapText(tester, 'Next');
      expect(find.text('Enter an email'), findsOneWidget);
      expectStep(tester, SignupStep.contact);
    });

    testWidgets('the fields read as their type, per step', (tester) async {
      await boot(tester);
      await typeInto(tester, 'name', 'Ann');
      await tapText(tester, 'Next');
      await typeInto(tester, 'email', 'ann@x.org');
      await tapText(tester, 'Next');
      expectStep(tester, SignupStep.review);
      expect(find.text('review Ann ann@x.org'), findsOneWidget);
    });

    testWidgets('marks the step done, and the others not', (tester) async {
      await boot(tester);
      var flow = flowOnScreen(tester);
      expect(flow.isComplete(SignupStep.name), isFalse);
      await typeInto(tester, 'name', 'Ann');
      await tapText(tester, 'Next');
      flow = flowOnScreen(tester);
      expect(flow.isComplete(SignupStep.name), isTrue);
      expect(flow.isComplete(SignupStep.contact), isFalse);
    });
  });

  group('skip', () {
    testWidgets('an individual has no company step', (tester) async {
      await boot(tester);
      var flow = flowOnScreen(tester);
      expect(flow.steps, [
        SignupStep.name,
        SignupStep.contact,
        SignupStep.review,
      ]);
      expect(flow.count, 3);
      expect(find.text('progress 0.33 (1 of 3)'), findsOneWidget);
      await typeInto(tester, 'name', 'Ann');
      await tapText(tester, 'Next');
      expectStep(tester, SignupStep.contact);
      expect(find.text('progress 0.67 (2 of 3)'), findsOneWidget);
      flow = flowOnScreen(tester);
      expect(flow.step, SignupStep.contact);
      expect(flow.isComplete(SignupStep.company), isFalse);
    });

    testWidgets('a business has one, and back returns to it', (tester) async {
      await boot(tester);
      await typeInto(tester, 'name', 'Ann');
      await tester.tap(find.byKey(const Key('business')));
      await tester.pump();
      expect(flowOnScreen(tester).count, 4);
      await tapText(tester, 'Next');
      expectStep(tester, SignupStep.company);
      expect(find.text('progress 0.50 (2 of 4)'), findsOneWidget);
      await tapText(tester, 'Next');
      expect(find.text('Enter the company'), findsOneWidget);
      await typeInto(tester, 'company', 'Acme');
      await tapText(tester, 'Next');
      expectStep(tester, SignupStep.contact);
      expect(
        flowOnScreen(tester).back(tester.element(find.byType(Scaffold).last)),
        isTrue,
      );
      await tester.pumpAndSettle();
      expectStep(tester, SignupStep.company);
      // What was typed stays: the form lives in the layout.
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('company')))
            .controller!
            .text,
        'Acme',
      );
    });
  });

  group('goTo', () {
    Future<void> toReview(WidgetTester tester) async {
      await typeInto(tester, 'name', 'Ann');
      await tapText(tester, 'Next');
      await typeInto(tester, 'email', 'ann@x.org');
      await tapText(tester, 'Next');
    }

    testWidgets('edits a step from the review, then goes on', (tester) async {
      await boot(tester);
      await toReview(tester);
      expectStep(tester, SignupStep.review);
      await tapText(tester, 'Edit name');
      expectStep(tester, SignupStep.name);
      await typeInto(tester, 'name', 'Anna');
      await tapText(tester, 'Next');
      // Every step before the review is done: the flow goes straight on.
      expectStep(tester, SignupStep.contact);
      await tapText(tester, 'Next');
      expect(find.text('review Anna ann@x.org'), findsOneWidget);
    });

    testWidgets('is refused to a step with one before it not done', (
      tester,
    ) async {
      await boot(tester);
      final flow = flowOnScreen(tester);
      final context = tester.element(find.byType(Scaffold).last);
      expect(flow.canGoTo(SignupStep.name), isTrue);
      expect(flow.canGoTo(SignupStep.contact), isFalse);
      expect(flow.goTo(context, SignupStep.review), isFalse);
      await tester.pumpAndSettle();
      expectStep(tester, SignupStep.name);
      // A step that is skipped cannot be opened either.
      expect(flow.canGoTo(SignupStep.company), isFalse);
    });
  });

  group('submit and the server\'s errors', () {
    Future<void> toReview(WidgetTester tester) async {
      await typeInto(tester, 'name', 'Ann');
      await tapText(tester, 'Next');
      await typeInto(tester, 'email', 'ann@x.org');
      await tapText(tester, 'Next');
    }

    testWidgets('runs the action with every step\'s fields', (tester) async {
      await boot(tester);
      await toReview(tester);
      await tapText(tester, 'Create');
      expect(sent, [
        (
          name: 'Ann',
          business: false,
          company: null,
          email: 'ann@x.org',
          phone: null,
        ),
      ]);
    });

    testWidgets('an error on a field goes to the first step that owns it', (
      tester,
    ) async {
      await boot(tester);
      await toReview(tester);
      serverErrors = {'email': 'Already used', 'name': 'Taken'};
      await tapText(tester, 'Create');
      // `name` is asked for before `email`.
      expectStep(tester, SignupStep.name);
      expect(find.text('Taken'), findsOneWidget);
      await typeInto(tester, 'name', 'Bea');
      expect(find.text('Taken'), findsNothing);
      serverErrors = {'email': 'Already used'};
      await tapText(tester, 'Next');
      expectStep(tester, SignupStep.contact);
      await tapText(tester, 'Next');
      await tapText(tester, 'Create');
      expectStep(tester, SignupStep.contact);
      expect(find.text('Already used'), findsOneWidget);
    });

    testWidgets('what no step owns, and the message, stay on the review', (
      tester,
    ) async {
      await boot(tester);
      await toReview(tester);
      serverErrors = {'nickname': 'Nope'};
      serverMessage = 'Could not sign up';
      await tapText(tester, 'Create');
      expectStep(tester, SignupStep.review);
      expect(find.text('error: Could not sign up\nNope'), findsOneWidget);
    });

    testWidgets('a field wrong at the end takes the flow to its step', (
      tester,
    ) async {
      await boot(tester);
      await toReview(tester);
      // Back to the name and empty it, then straight to the review by the router.
      router.go('/signup/name');
      await tester.pumpAndSettle();
      await typeInto(tester, 'name', '');
      router.go('/signup/review');
      await tester.pumpAndSettle();
      await tapText(tester, 'Create');
      expectStep(tester, SignupStep.name);
      expect(find.text('Enter your name'), findsOneWidget);
      expect(sent, isEmpty);
    });

    testWidgets('a sync action stays sync: submit returns its value', (
      tester,
    ) async {
      var ran = 0;
      final syncAction = actionProvider<SignupFields, int>(
        (Ref ref, SignupFields input) => ++ran,
        invalidates: () => const <ProviderListenable<AsyncValue<Object?>>>[],
        site: 'a9_0',
      );
      FormFlow<SignupFields, int, SignupStep, SignupFlowFields>? flow;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [formDraftStorage.overrideWithValue(null)],
          child: MaterialApp(
            home: HookConsumer(
              builder: (context, ref, _) {
                flow = SignupSection._flow.use(ref, syncAction, draft: null);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      flow!.fields.name.value = 'Ann';
      flow!.fields.email.value = 'ann@x.org';
      final result = flow!.submit();
      expect(result, 1);
      expect(result, isNot(isA<Future<Object?>>()));
      expect(ran, 1);
    });
  });

  group('the draft', () {
    testWidgets('keeps the fields and the steps done, and a restart finds '
        'them', (tester) async {
      final container = await boot(tester);
      await typeInto(tester, 'name', 'Ann');
      await tapText(tester, 'Next');
      await typeInto(tester, 'email', 'ann@x');
      // Saved when the step changed: the name and the step done, not yet the email.
      expect(await readFormDraft(container, id: id, shape: shape), {
        'name': 'Ann',
      });
      expect(await readFormDraftSteps(container, id: id, shape: shape), [
        'name',
      ]);
      // The app goes away and comes back at the step it was on.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(await readFormDraft(reader(), id: id, shape: shape), {
        'name': 'Ann',
        'email': 'ann@x',
      });
      await boot(tester, at: '/signup/contact');
      expectStep(tester, SignupStep.contact);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('email')))
            .controller!
            .text,
        'ann@x',
      );
      expect(flowOnScreen(tester).isComplete(SignupStep.name), isTrue);
      expect(flowOnScreen(tester).isComplete(SignupStep.contact), isFalse);
    });

    testWidgets('survives a back and a forward through the router', (
      tester,
    ) async {
      await boot(tester);
      await typeInto(tester, 'name', 'Ann');
      await tapText(tester, 'Next');
      await typeInto(tester, 'email', 'ann@x.org');
      // The browser's back is a `go` to the earlier location.
      router.go('/signup/name');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('name')))
            .controller!
            .text,
        'Ann',
      );
      router.go('/signup/contact');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('email')))
            .controller!
            .text,
        'ann@x.org',
      );
      expect(asked, isEmpty);
    });

    testWidgets('is written when the layout goes', (tester) async {
      await boot(tester);
      await typeInto(tester, 'name', 'Ann');
      await tapText(tester, 'Next');
      await typeInto(tester, 'email', 'ann@x.org');
      await tester.pumpWidget(const SizedBox());
      expect(await readFormDraft(reader(), id: id, shape: shape), {
        'name': 'Ann',
        'email': 'ann@x.org',
      });
    });

    testWidgets('is cleared when the form is sent', (tester) async {
      final container = await boot(tester);
      await typeInto(tester, 'name', 'Ann');
      await tapText(tester, 'Next');
      await typeInto(tester, 'email', 'ann@x.org');
      await tapText(tester, 'Next');
      await tapText(tester, 'Create');
      expect(await readFormDraft(container, id: id, shape: shape), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(await readFormDraft(reader(), id: id, shape: shape), isNull);
    });

    testWidgets('draft: null keeps nothing, and the steps still work', (
      tester,
    ) async {
      draftOf = null;
      final container = await boot(tester);
      await typeInto(tester, 'name', 'Ann');
      await tapText(tester, 'Next');
      expectStep(tester, SignupStep.contact);
      expect(await readFormDraft(container, id: id, shape: shape), isNull);
      // The flow in memory is what the guard asks: no draft, and the next step opens.
      await typeInto(tester, 'email', 'ann@x.org');
      await tapText(tester, 'Next');
      expectStep(tester, SignupStep.review);
    });
  });

  group('deep links and resume', () {
    testWidgets('a link past what was done goes to the first step not done', (
      tester,
    ) async {
      await boot(tester, at: '/signup/review');
      expectStep(tester, SignupStep.name);
    });

    testWidgets('a link to a step that may open is left alone', (tester) async {
      await boot(tester, at: '/signup/name');
      expectStep(tester, SignupStep.name);
    });

    testWidgets('a draft lets the link through as far as it was done', (
      tester,
    ) async {
      await boot(tester); // a container to seed the storage with
      final container = ProviderContainer(
        overrides: [formDraftStorage.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(const SizedBox());
      await seedFormDraft(
        container,
        id: id,
        shape: shape,
        fields: {'name': 'Ann', 'email': 'ann@x.org'},
        steps: {SignupStep.name},
      );
      await boot(tester, at: '/signup/review');
      // `name` is done, `contact` is not: the review is past it.
      expectStep(tester, SignupStep.contact);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('email')))
            .controller!
            .text,
        'ann@x.org',
      );
      expect(flowOnScreen(tester).fields.name.value, 'Ann');
    });

    testWidgets('a draft that did every step opens the review', (tester) async {
      final container = ProviderContainer(
        overrides: [formDraftStorage.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      await seedFormDraft(
        container,
        id: id,
        shape: shape,
        fields: {'name': 'Ann', 'email': 'ann@x.org'},
        steps: {SignupStep.name, SignupStep.contact},
      );
      await boot(tester, at: '/signup/review');
      expectStep(tester, SignupStep.review);
    });

    testWidgets('a draft for another shape is no draft', (tester) async {
      final container = ProviderContainer(
        overrides: [formDraftStorage.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      await seedFormDraft(
        container,
        id: id,
        shape: 'name:String',
        fields: {'name': 'Ann'},
        steps: {SignupStep.name, SignupStep.contact},
      );
      await boot(tester, at: '/signup/review');
      expectStep(tester, SignupStep.name);
    });

    testWidgets('an async storage makes the guard wait for it', (tester) async {
      final late = Completer<Storage<String, String>?>();
      final container = ProviderContainer(
        overrides: [formDraftStorage.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      await seedFormDraft(
        container,
        id: id,
        shape: shape,
        fields: {'name': 'Ann', 'email': 'ann@x.org'},
        steps: {SignupStep.name, SignupStep.contact},
      );
      router = makeRouter('/signup/review');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [formDraftStorage.overrideWithValue(late.future)],
          retry: (_, _) => null,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      expect(find.byType(SignupLayout), findsNothing);
      late.complete(storage);
      await tester.pumpAndSettle();
      expectStep(tester, SignupStep.review);
    });
  });

  group('leaving', () {
    Future<void> dirty(WidgetTester tester) async {
      await typeInto(tester, 'name', 'Ann');
    }

    testWidgets('is not asked between the steps, in either direction', (
      tester,
    ) async {
      await boot(tester);
      await dirty(tester);
      await tapText(tester, 'Next');
      await typeInto(tester, 'email', 'ann@x.org');
      await tapText(tester, 'Next');
      router.go('/signup/name');
      await tester.pumpAndSettle();
      router.go('/signup/review');
      await tester.pumpAndSettle();
      expect(asked, isEmpty);
      expect(find.text('Discard your changes?'), findsNothing);
    });

    testWidgets('is asked once, when the flow is left', (tester) async {
      await boot(tester);
      await dirty(tester);
      await tapText(tester, 'Next');
      router.go('/');
      await tester.pumpAndSettle();
      expect(asked, hasLength(1));
      expect(find.text('Discard your changes?'), findsOneWidget);
      await tapText(tester, 'Keep editing');
      expectStep(tester, SignupStep.contact);
      router.go('/');
      await tester.pumpAndSettle();
      await tapText(tester, 'Discard');
      expect(find.text('Home'), findsOneWidget);
      expect(asked, hasLength(2));
    });

    testWidgets('a flow with nothing typed goes without asking', (
      tester,
    ) async {
      await boot(tester);
      router.go('/');
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Discard your changes?'), findsNothing);
    });

    testWidgets('"Keep as draft" saves the fields and the steps', (
      tester,
    ) async {
      final container = await boot(tester);
      await dirty(tester);
      await tapText(tester, 'Next');
      await typeInto(tester, 'email', 'ann@x.org');
      router.go('/');
      await tester.pumpAndSettle();
      await tapText(tester, 'Keep as draft');
      expect(find.text('Home'), findsOneWidget);
      expect(await readFormDraft(container, id: id, shape: shape), {
        'name': 'Ann',
        'email': 'ann@x.org',
      });
      expect(await readFormDraftSteps(container, id: id, shape: shape), [
        'name',
      ]);
    });

    testWidgets('"Discard" drops the draft too', (tester) async {
      final container = await boot(tester);
      await dirty(tester);
      await tapText(tester, 'Next');
      router.go('/');
      await tester.pumpAndSettle();
      await tapText(tester, 'Discard');
      expect(await readFormDraft(container, id: id, shape: shape), isNull);
    });

    testWidgets('an answer given in a test needs no sheet', (tester) async {
      await boot(tester, overrides: [LeavePrompts.answer(LeaveChoice.stay)]);
      await dirty(tester);
      router.go('/');
      await tester.pumpAndSettle();
      expectStep(tester, SignupStep.name);
      expect(find.text('Discard your changes?'), findsNothing);
    });
  });

  group('the system back', () {
    testWidgets('goes to the previous step, not out of the flow', (
      tester,
    ) async {
      await boot(tester);
      await typeInto(tester, 'name', 'Ann');
      await tapText(tester, 'Next');
      await typeInto(tester, 'email', 'ann@x.org');
      await tapText(tester, 'Next');
      expectStep(tester, SignupStep.review);
      await systemBack(tester);
      expectStep(tester, SignupStep.contact);
      await systemBack(tester);
      expectStep(tester, SignupStep.name);
      expect(asked, isEmpty);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('name')))
            .controller!
            .text,
        'Ann',
      );
    });

    testWidgets('on the first step it leaves the flow: asked, once', (
      tester,
    ) async {
      await boot(tester);
      await typeInto(tester, 'name', 'Ann');
      await systemBack(tester, wait: false);
      expect(asked, hasLength(1));
      expect(find.text('Discard your changes?'), findsOneWidget);
      await tapText(tester, 'Keep editing');
      expectStep(tester, SignupStep.name);
    });
  });

  group('the progress', () {
    testWidgets('counts the steps that are shown', (tester) async {
      await boot(tester);
      final flow = flowOnScreen(tester);
      expect(flow.step, SignupStep.name);
      expect(flow.index, 0);
      expect(flow.count, 3);
      expect(flow.isFirst, isTrue);
      expect(flow.isLast, isFalse);
      expect(flow.progress, closeTo(1 / 3, 1e-9));
    });
  });

  group('an app that was not given the pieces', () {
    testWidgets('FormFlow.of without a scope says what is missing', (
      tester,
    ) async {
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            expect(
              () =>
                  FormFlow.of<
                    SignupFields,
                    Object?,
                    SignupStep,
                    SignupFlowFields
                  >(context),
              throwsFlutterError,
            );
            return const SizedBox();
          },
        ),
      );
    });
  });
}
