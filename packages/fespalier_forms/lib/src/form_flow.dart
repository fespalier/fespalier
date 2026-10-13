// The multi-page form (since 0.11.0): the steps of a section share one `ActionForm`, which the
// section's layout owns. A part of action_form.dart because it is that machinery, with one more
// idea: a field belongs to a step, and a step is a page. Nothing here starts a timer or a
// microtask; a step changes on an event (`next`, `back`, `goTo`) and the draft is written there.
part of 'action_form.dart';

/// The flows whose layout is on screen, by the key of their draft: what a guard's `resume` asks
/// first, because the form in memory knows the steps done even when no draft is kept.
final Map<String, FormFlow<Object?, Object?, Enum, Record>> _liveFlows = {};

/// The path of [location] without a trailing slash, for comparing a step's route with where the
/// router is.
String _flowPath(String location) {
  final path = Uri.parse(location).path;
  return path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
}

/// The step of [routes] whose location has this [path], or null.
S? _stepAtPath<S extends Enum>(Map<S, TypedLocation> routes, String? path) {
  if (path == null) return null;
  final here = _flowPath(path);
  for (final MapEntry(:key, :value) in routes.entries) {
    if (_flowPath(value.location) == here) return key;
  }
  return null;
}

/// Calls [then] with [value] now when it is one, when it completes when it is a Future.
FutureOr<R> _whenReady<T, R>(
  FutureOr<T> value,
  FutureOr<R> Function(T value) then,
) => value is Future<T> ? value.then(then) : then(value);

/// The form of an action asked over the pages of a section (since 0.11.0): the typed [fields] of
/// an [ActionForm], shared by every step, and which step is on screen, which are done and where to
/// go next.
///
/// The section's layout makes one with the generated `useFlow` and puts it in a
/// [FormFlowScope]; a step page reads it with `flowOf(context)`. A field belongs to the step that
/// asks for it (the `const steps` of the action.dart): [next] checks only that step's fields.
///
/// ```dart
/// final flow = SignupSection.flowOf(context);
/// final f = flow.fields;
/// TextField(controller: f.email.controller, decoration: InputDecoration(errorText: f.email.error));
/// FilledButton(onPressed: flow.isPending ? null : () => flow.next(context), child: const Text('Next'));
/// ```
final class FormFlow<I, T, S extends Enum, F extends Record>
    extends ActionForm<I, T, F> {
  FormFlow._(
    _ActionFormHook<I, T, F> hook, {
    required List<S> steps,
    required Map<S, TypedLocation> routes,
    required Map<String, S> owners,
    required bool Function(S step, I input)? skip,
    required String liveKey,
  }) : _steps = steps,
       _routes = routes,
       _owners = owners,
       _skip = skip,
       _liveKey = liveKey,
       super._(
         hook.action,
         hook.initial,
         hook.fields,
         hook.input,
         hook.validate,
         hook.messages,
         hook.validation,
         false,
       );

  /// A flow that is read and thrown away: what a guard's `resume` builds to know the steps a draft
  /// has done, with no action to run.
  FormFlow._throwaway({
    required List<S> steps,
    required Map<S, TypedLocation> routes,
    required Map<String, S> owners,
    required bool Function(S step, I input)? skip,
    required I Function() initial,
    required F Function(ActionFormFields<I> f) fields,
    required I Function(F fields) input,
  }) : _steps = steps,
       _routes = routes,
       _owners = owners,
       _skip = skip,
       _liveKey = '',
       super._(
         () => throw StateError('a flow that is only read runs no action'),
         initial,
         fields,
         input,
         null,
         const ActionFormMessages(),
         ActionFormValidation.afterSubmit,
         false,
       );

  final List<S> _steps;
  final Map<S, TypedLocation> _routes;
  final Map<String, S> _owners;
  final bool Function(S step, I input)? _skip;
  final String _liveKey;

  /// The steps done: [next] adds one, and so does a draft that is read.
  final Set<S> _done = {};

  /// The steps whose fields show their errors: the ones [next] was asked on.
  final Set<S> _shown = {};

  GoRouter? _router;

  /// The flow of the layout above [context], a [FormFlowScope] (since 0.11.0). A page that reads it
  /// is rebuilt when the flow changes. Throws when there is no scope above.
  static FormFlow<I, T, S, F> of<I, T, S extends Enum, F extends Record>(
    BuildContext context,
  ) {
    final flow = maybeOf<I, T, S, F>(context);
    if (flow == null) {
      throw FlutterError(
        'FormFlow.of() was called with a context that has no FormFlowScope above it.\n'
        'A flow is made by the layout of its section (`useFlow`) and put around its `child` in a '
        'FormFlowScope; the step pages are below that layout.',
      );
    }
    return flow;
  }

  /// Like [of], or null when there is no scope above [context].
  static FormFlow<I, T, S, F>? maybeOf<I, T, S extends Enum, F extends Record>(
    BuildContext context,
  ) {
    final scope = context.dependOnInheritedWidgetOfExactType<FormFlowScope>();
    final flow = scope?.flow;
    if (flow == null) return null;
    if (flow is! FormFlow<I, T, S, F>) {
      throw FlutterError(
        'FormFlow.of() found the flow of another section: ${flow.runtimeType}, not '
        '$FormFlow<$I, $T, $S, $F>.',
      );
    }
    return flow;
  }

  // ---- where the flow is --------------------------------------------------------------------

  /// The steps that are shown, in order: every step but those `skip()` leaves out for the input as
  /// it is now.
  List<S> get steps => List.unmodifiable(_visible());

  List<S> _visible() {
    final skip = _skip;
    if (skip == null) return _steps;
    final input = _input(fields);
    return [
      for (final s in _steps)
        if (!skip(s, input)) s,
    ];
  }

  /// The step on screen, from the router's location. The first step when the location is none of
  /// them (a flow with no router, in a test of the form alone).
  S get step =>
      _stepAtPath(
        _routes,
        _router?.routerDelegate.currentConfiguration.uri.path,
      ) ??
      _steps.first;

  /// The position of [step] among the [steps] that are shown, from 0; a step that is left out
  /// (a deep link to it) has the position of the one that follows it.
  int get index {
    final visible = _visible();
    if (visible.isEmpty) return 0;
    final here = step;
    final shown = visible.indexOf(here);
    if (shown >= 0) return shown;
    final at = _steps.indexOf(here);
    final before = visible.where((s) => _steps.indexOf(s) < at).length;
    return before.clamp(0, visible.length - 1);
  }

  /// How many steps are shown.
  int get count => _visible().length;

  /// How far the flow is, from 0 to 1: the position of [step] among the [steps], counted from 1,
  /// so the first of four is 0.25 and the last is 1. For a `LinearProgressIndicator(value:)`.
  double get progress {
    final n = count;
    return n == 0 ? 0 : (index + 1) / n;
  }

  /// Whether [step] is the first of the steps shown: there is nowhere to go [back] to.
  bool get isFirst => index == 0;

  /// Whether [step] is the last of the steps shown: [next] runs the action there.
  bool get isLast => index >= count - 1;

  /// Whether the user has been through [step] with [next] and its fields were fine (or a draft
  /// says so).
  bool isComplete(S step) => _done.contains(step);

  /// Whether [goTo] may open [target]: it is shown, and every step shown before it is complete.
  bool canGoTo(S target) {
    final visible = _visible();
    if (!visible.contains(target)) return false;
    for (final s in visible) {
      if (s == target) return true;
      if (!_done.contains(s)) return false;
    }
    return true;
  }

  S? _after(S here) {
    final at = _steps.indexOf(here);
    for (final s in _visible()) {
      if (_steps.indexOf(s) > at) return s;
    }
    return null;
  }

  S? _before(S here) {
    final at = _steps.indexOf(here);
    S? found;
    for (final s in _visible()) {
      if (_steps.indexOf(s) < at) found = s;
    }
    return found;
  }

  // ---- moving -------------------------------------------------------------------------------

  /// Checks the fields of [step] alone (what each reads as, and what `validate()` says of them),
  /// then marks it done, keeps the draft and goes to the next step shown. On the last step it
  /// runs the action, as [submit] does. Returns false, with the errors shown under the fields,
  /// when a field of the step is wrong.
  bool next(BuildContext context) {
    final here = step;
    if (!_stepIsValid(here)) {
      notifyListeners();
      return false;
    }
    _done.add(here);
    _keepDraft();
    final after = _after(here);
    if (after == null) {
      _submitQuietly();
    } else {
      _go(context, after);
    }
    notifyListeners();
    return true;
  }

  /// Goes to the previous step shown, keeping the draft; false when [step] is the first. What is
  /// typed stays where it is: the form lives in the layout.
  bool back(BuildContext context) {
    final before = _before(step);
    if (before == null) return false;
    _keepDraft();
    _go(context, before);
    return true;
  }

  /// Goes to [target] (to edit from a review) when [canGoTo] allows it; false otherwise.
  bool goTo(BuildContext context, S target) {
    if (!canGoTo(target)) return false;
    if (target != step) {
      _keepDraft();
      _go(context, target);
    }
    return true;
  }

  void _go(BuildContext? context, S target) {
    final router =
        (context == null ? null : GoRouter.maybeOf(context)) ?? _router;
    final route = _routes[target];
    if (router == null || route == null) return;
    router.go(route.location);
  }

  bool _stepIsValid(S here) {
    _shown.add(here);
    final owned = [
      for (final f in _all)
        if (_owners[f.name] == here) f,
    ];
    if (owned.any((f) => f._parseError != null)) return false;
    final errors = _check(_input(fields)).fields;
    return !owned.any((f) => errors.containsKey(f.name));
  }

  /// The first step shown (in order) with a field that is wrong, or null.
  S? _firstFailing() {
    final errors = _check(_input(fields)).fields;
    for (final s in _visible()) {
      for (final f in _all) {
        if (_owners[f.name] != s) continue;
        if (f._parseError != null || errors.containsKey(f.name)) return s;
      }
    }
    return null;
  }

  /// Checks every field, then runs the action with all of them. A field that is wrong takes the
  /// flow to the first step that asks for it, with the error shown; the errors of the server
  /// (the action's [FieldErrors]) do the same, and what belongs to no field (the message, a key
  /// that is none) is in [error]. Returns what the action returned, as [ActionForm.submit].
  @override
  FutureOr<T?> submit() {
    final bad = _firstFailing();
    if (bad != null) {
      _submitted = true;
      _fromAction = const {};
      if (bad != step) _go(null, bad);
      notifyListeners();
      return null;
    }
    return super.submit();
  }

  @override
  void _failed(Object error) {
    super._failed(error);
    if (_disposed || error is! FieldErrors) return;
    // The server's errors are on their fields; the first step that owns one is where to look.
    for (final s in _visible()) {
      final owns = error.fields.keys.any((k) => _owners[k] == s);
      if (!owns) continue;
      if (s != step) _go(null, s);
      return;
    }
  }

  @override
  void _succeeded() {
    _done.clear();
    _shown.clear();
    super._succeeded();
  }

  @override
  void reset() {
    _done.clear();
    _shown.clear();
    super.reset();
  }

  @override
  bool _shows(ActionField<Object?> field) {
    if (super._shows(field)) return true;
    final owner = _owners[field.name];
    return owner != null && _shown.contains(owner);
  }

  // ---- the draft ----------------------------------------------------------------------------

  void _keepDraft() {
    if (_drafts != null && !_discarded) _let(_saveDraft());
  }

  @override
  List<String> _draftSteps() => [
    for (final s in _steps)
      if (_done.contains(s)) s.name,
  ];

  @override
  void _restoreSteps(List<String> saved) {
    _done.addAll([
      for (final s in _steps)
        if (saved.contains(s.name)) s,
    ]);
  }

  @override
  bool get _worthKeeping => isDirty || _done.isNotEmpty;

  // ---- resuming -----------------------------------------------------------------------------

  /// Where a navigation to [target] goes instead, or null when it may open: [target] is shown and
  /// every step shown before it is done. Otherwise the first step not done.
  String? _redirectFor(S target) {
    final visible = _visible();
    if (visible.isEmpty) return null;
    if (canGoTo(target)) return null;
    final open = visible.firstWhere(
      (s) => !_done.contains(s),
      orElse: () => visible.last,
    );
    if (open == target) return null;
    return _routes[open]?.location;
  }

  @override
  void _attached(BuildContext context) {
    _router = GoRouter.maybeOf(context);
    _liveFlows[_liveKey] = this;
  }

  @override
  void _detached() {
    if (identical(_liveFlows[_liveKey], this)) _liveFlows.remove(_liveKey);
  }
}

/// What a layout puts around its `child` to share its [FormFlow] with the step pages below it
/// (since 0.11.0). Pages read the flow with the generated `flowOf(context)`, and are rebuilt when it
/// changes.
final class FormFlowScope extends InheritedNotifier<ChangeNotifier> {
  /// Shares [flow] with everything below.
  const FormFlowScope({
    super.key,
    required FormFlow<Object?, Object?, Enum, Record> flow,
    required super.child,
  }) : super(notifier: flow);

  /// The flow it shares.
  FormFlow<Object?, Object?, Enum, Record>? get flow {
    final n = notifier;
    return n is FormFlow<Object?, Object?, Enum, Record> ? n : null;
  }
}

/// What the generated step page builder wraps a step's page in, inside `leaveScope` (since
/// 0.11.0): the flow of the layout above is registered in the page's `LeaveScope`, so a
/// `leave()` asked when the page goes sees whether the form has unsaved changes, and, on every
/// step but the first, the system back goes to the previous step instead of leaving the flow.
Widget flowStep(Widget child) => _FlowStep(child: child);

final class _FlowStep extends StatefulWidget {
  const _FlowStep({required this.child});

  final Widget child;

  @override
  State<_FlowStep> createState() => _FlowStepState();
}

final class _FlowStepState extends State<_FlowStep> {
  FormFlow<Object?, Object?, Enum, Record>? _flow;
  VoidCallback? _unregister;
  VoidCallback? _unregisterBack;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final flow = context
        .dependOnInheritedWidgetOfExactType<FormFlowScope>()
        ?.flow;
    if (!identical(flow, _flow)) {
      _unregister?.call();
      _unregister = null;
      _flow = flow;
      if (flow != null) {
        _unregister = LeaveScope.maybeOf(context)?.register(flow);
      }
    }
    _syncBack();
  }

  /// A back handler only while there is a previous step: on the first step the back is the
  /// page's own (leave the flow, asked once).
  void _syncBack() {
    final wants = _flow != null && !_flow!.isFirst;
    if (wants && _unregisterBack == null) {
      _unregisterBack = LeaveScope.maybeOf(context)?.onBack(_back);
    } else if (!wants) {
      _unregisterBack?.call();
      _unregisterBack = null;
    }
  }

  bool _back() {
    final flow = _flow;
    if (flow == null || !mounted || flow.isFirst) return false;
    return flow.back(context);
  }

  @override
  void dispose() {
    _unregister?.call();
    _unregisterBack?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The hook behind the generated `useFlow` (since 0.11.0): a [FormFlow] for [action] that lives as
/// long as the layout that calls it, rebuilt when it changes.
///
/// [steps] are the steps in order, [routes] the location of each step's page and [owners] the step
/// that asks for each field of the input; [skip] says which steps are left out for an input. The
/// rest is [useActionForm]'s. The [draft] is on by default, and keeps the steps done with the
/// fields: back, forward and a restart of the app find the form as it was; pass null to keep none.
FormFlow<I, T, S, F> useFormFlow<I, T, S extends Enum, F extends Record>(
  WidgetRef ref,
  ActionProvider<I, T> action, {
  required String id,
  List<Object?> key = const [],
  required String shape,
  required List<S> steps,
  required Map<S, TypedLocation> routes,
  required Map<String, S> owners,
  bool Function(S step, I input)? skip,
  required I Function() initial,
  required F Function(ActionFormFields<I> f) fields,
  required I Function(F fields) input,
  FieldErrors? Function(I input)? validate,
  ActionFormValidation validation = ActionFormValidation.afterSubmit,
  ActionFormMessages messages = const ActionFormMessages(),
  FormDraft? draft = const FormDraft(),
}) {
  assert(steps.isNotEmpty, 'a flow needs at least one step');
  assert(
    draft == null || id.isNotEmpty,
    'a flow with a draft needs an `id` (the generated useFlow passes the action file and name)',
  );
  final liveKey = draftKey(id, key, ref.read(formDraftScope));
  final _Drafts Function()? drafts = draft == null
      ? null
      : () => _Drafts(ref.read(formDraftStorage), liveKey, shape, draft);
  final form = use(
    _ActionFormHook<I, T, F>(
      () => ref.read(action.notifier),
      ref.watch(action),
      null,
      initial,
      fields,
      input,
      validate,
      validation,
      false,
      messages,
      drafts,
      create: (hook) => FormFlow<I, T, S, F>._(
        hook,
        steps: steps,
        routes: routes,
        owners: owners,
        skip: skip,
        liveKey: liveKey,
      ),
      keys: [action],
    ),
  );
  return form as FormFlow<I, T, S, F>;
}

/// What a guard returns to resume a flow (since 0.11.0): where the first step not done is, when
/// [uri] is a step past it, else null. The generated `resume` is this with the flow's own
/// arguments.
///
/// What is done is read from the flow whose layout is on screen when there is one (the steps done
/// in this run, with no draft needed), else from the draft, so a deep link or a restart opens the
/// step the user had reached, and a link past what was done is sent back to the first step
/// not done. A `uri` that is no step's is left alone. An answer that needs the draft's storage
/// is a `Future`; a failure to read it lets the navigation through.
GuardResult flowResume<I, S extends Enum, F extends Record>(
  Ref ref, {
  required String id,
  List<Object?> key = const [],
  required String shape,
  required List<S> steps,
  required Map<S, TypedLocation> routes,
  required Map<String, S> owners,
  bool Function(S step, I input)? skip,
  required I Function() initial,
  required F Function(ActionFormFields<I> f) fields,
  required I Function(F fields) input,
  required Uri uri,
}) {
  final target = _stepAtPath(routes, uri.path);
  if (target == null) return null;
  final dKey = draftKey(id, key, ref.read(formDraftScope));
  final live = _liveFlows[dKey];
  if (live is FormFlow<I, Object?, S, F>) return live._redirectFor(target);

  String? decide(DraftEntry? entry) {
    final flow = FormFlow<I, Object?, S, F>._throwaway(
      steps: steps,
      routes: routes,
      owners: owners,
      skip: skip,
      initial: initial,
      fields: fields,
      input: input,
    );
    try {
      if (entry != null) {
        flow._drafts = _Drafts(null, dKey, shape, const FormDraft());
        flow._applyDraft(entry, deferred: false);
      }
      return flow._redirectFor(target);
    } on Object catch (error) {
      if (kDebugMode) debugPrint('fespalier_forms: resume: $error');
      return null;
    } finally {
      // Read and thrown away: it keeps no draft.
      flow._drafts = null;
      flow.dispose();
    }
  }

  final storage = ref.read(formDraftStorage);
  return _whenReady<Storage<String, String>?, String?>(storage, (opened) {
    if (opened == null) return decide(null);
    return _whenReady<DraftEntry?, String?>(
      loadDraftEntry(opened, dKey, shape),
      decide,
    );
  });
}

/// Everything a flow is made of, which the generated section class holds once and its `useFlow`,
/// `flowOf` and `resume` go through (since 0.11.0). It exists so that the types of the form
/// (`I`, `S` and the record of fields `F`) are inferred in one place, from the generated closures,
/// and the page that reads the flow gets them: an app has no reason to make one.
final class FlowSpec<I, S extends Enum, F extends Record> {
  /// Holds the parts of the form; see [useFormFlow] for each.
  FlowSpec({
    required this.id,
    required this.shape,
    required this.steps,
    required this.routes,
    required this.owners,
    this.skip,
    required this.initial,
    required this.fields,
    required this.input,
    this.validate,
  });

  /// The action's file and name, which keys the draft.
  final String id;

  /// The form's fields and types.
  final String shape;

  /// The steps in order.
  final List<S> steps;

  /// The page of each step.
  final Map<S, TypedLocation> routes;

  /// The step that asks for each field.
  final Map<String, S> owners;

  /// Which steps are left out.
  final bool Function(S step, I input)? skip;

  /// What the form starts from.
  final I Function() initial;

  /// Builds the fields.
  final F Function(ActionFormFields<I> f) fields;

  /// The action's input from the fields.
  final I Function(F fields) input;

  /// `validate()`, when the action has one.
  final FieldErrors? Function(I input)? validate;

  /// The generated `useFlow`: [useFormFlow] with this spec's parts.
  FormFlow<I, T, S, F> use<T>(
    WidgetRef ref,
    ActionProvider<I, T> action, {
    List<Object?> key = const [],
    ActionFormValidation validation = ActionFormValidation.afterSubmit,
    FormDraft? draft = const FormDraft(),
    ActionFormMessages messages = const ActionFormMessages(),
  }) => useFormFlow<I, T, S, F>(
    ref,
    action,
    id: id,
    key: key,
    shape: shape,
    steps: steps,
    routes: routes,
    owners: owners,
    skip: skip,
    initial: initial,
    fields: fields,
    input: input,
    validate: validate,
    validation: validation,
    messages: messages,
    draft: draft,
  );

  /// The generated `flowOf`: the flow of the layout above [context], typed by this spec (its
  /// result type is `Object?`: a step page has no use for it).
  FormFlow<I, Object?, S, F> of(BuildContext context) =>
      FormFlow.of<I, Object?, S, F>(context);

  /// The generated `resume`: [flowResume] with this spec's parts.
  GuardResult resume(
    Ref ref, {
    List<Object?> key = const [],
    required Uri uri,
  }) => flowResume<I, S, F>(
    ref,
    id: id,
    key: key,
    shape: shape,
    steps: steps,
    routes: routes,
    owners: owners,
    skip: skip,
    initial: initial,
    fields: fields,
    input: input,
    uri: uri,
  );
}
