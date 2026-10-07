import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/persist.dart' show Storage;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'draft_store.dart';
import 'drafts.dart';

/// The messages a form shows for text it cannot read as its field's type (since 0.8.1). Pass your
/// own, translated, to the generated `useForm`.
final class ActionFormMessages {
  /// The English defaults, or the messages given.
  const ActionFormMessages({
    this.required = 'Required',
    this.integer = 'Enter a whole number',
    this.number = 'Enter a number',
  });

  /// An empty text field whose type is not nullable (`int`, `double`, `num`).
  final String required;

  /// Text in an `int` field that is not a whole number.
  final String integer;

  /// Text in a `double` or `num` field that is not a number.
  final String number;
}

enum _Kind { text, integer, decimal, number }

/// How the text of a text field becomes the field's value and back (since 0.8.1). The generated
/// `useForm` picks one by the field's type; there is one per type a text field can hold.
final class FieldCodec<V> {
  const FieldCodec._(this._kind, this._optional);

  /// `String`: the text as typed.
  static const FieldCodec<String> text = FieldCodec<String>._(
    _Kind.text,
    false,
  );

  /// `String?`: null when empty.
  static const FieldCodec<String?> optionalText = FieldCodec<String?>._(
    _Kind.text,
    true,
  );

  /// `int`.
  static const FieldCodec<int> integer = FieldCodec<int>._(
    _Kind.integer,
    false,
  );

  /// `int?`: null when empty.
  static const FieldCodec<int?> optionalInteger = FieldCodec<int?>._(
    _Kind.integer,
    true,
  );

  /// `double`.
  static const FieldCodec<double> decimal = FieldCodec<double>._(
    _Kind.decimal,
    false,
  );

  /// `double?`: null when empty.
  static const FieldCodec<double?> optionalDecimal = FieldCodec<double?>._(
    _Kind.decimal,
    true,
  );

  /// `num`.
  static const FieldCodec<num> number = FieldCodec<num>._(_Kind.number, false);

  /// `num?`: null when empty.
  static const FieldCodec<num?> optionalNumber = FieldCodec<num?>._(
    _Kind.number,
    true,
  );

  final _Kind _kind;
  final bool _optional;

  /// The text a field shows for [value].
  String format(V value) => value == null ? '' : '$value';

  /// The value [text] stands for, or the message that says why it is none.
  ({V? value, String? error}) parse(String text, ActionFormMessages messages) {
    if (_kind == _Kind.text) {
      return (
        value: (_optional && text.isEmpty ? null : text) as V?,
        error: null,
      );
    }
    final t = text.trim();
    if (t.isEmpty) {
      return _optional
          ? (value: null, error: null)
          : (value: null, error: messages.required);
    }
    final Object? v = switch (_kind) {
      _Kind.integer => int.tryParse(t),
      _Kind.decimal => double.tryParse(t),
      _Kind.number => num.tryParse(t),
      _Kind.text => t,
    };
    if (v == null) {
      final message = _kind == _Kind.integer
          ? messages.integer
          : messages.number;
      return (value: null, error: message);
    }
    return (value: v as V, error: null);
  }
}

/// When a form shows what `validate()` says of its fields (since 0.8.1). The action's own
/// [FieldErrors] show when it fails, whichever this is.
enum ActionFormValidation {
  /// Nothing until the first submit, then every field as it changes. The default.
  afterSubmit,

  /// A field as soon as it is changed, every field after a submit.
  onChange,
}

/// One field of an action's form (since 0.8.1): its typed [value], the [error] to show and whether
/// it [isDirty]. A field of another type than text binds through [value] and [didChange]
/// (`Checkbox(value: f.express.value, onChanged: f.express.didChange)`).
base class ActionField<V> {
  ActionField._(this._form, this.name, this._get, V initial, [this._draft])
    : _initial = initial,
      _value = initial;

  final ActionForm<Object?, Object?, Record> _form;

  /// Reads this field's value out of an input: how the form starts it again from new data.
  final V Function(Object? input) _get;

  /// How a draft keeps this field's value; null: a field of this type is not drafted.
  final DraftCodec<V>? _draft;

  /// The name of the field in the action's input, which is the key of its [FieldErrors].
  final String name;

  V _initial;
  V _value;
  bool _changed = false;

  /// The value the input gets for this field.
  V get value => _value;

  /// Sets the value, as the user would.
  set value(V value) => didChange(value);

  /// Sets the value, as the user would; null is ignored for a field whose type is not nullable,
  /// so it fits `onChanged` of a `Checkbox` or a `DropdownButton`.
  void didChange(V? value) {
    if (value is! V) return;
    _value = value;
    _changed = true;
    _form._fieldChanged(this);
  }

  /// Whether the value differs from what the form started from.
  bool get isDirty => _value != _initial;

  /// The message to show under the field, or null.
  String? get error => _form._errorOf(this);

  String? get _parseError => null;

  /// Whether a draft keeps this field.
  bool get _drafted => _draft != null;

  /// What a draft writes for this field.
  Object? _draftValue() => _draft!.encode(_value);

  /// Takes the value a draft kept, without telling anyone: the form says so once it is done.
  void _restoreDraft(Object? saved) {
    _value = _draft!.decode(saved);
    _changed = isDirty;
  }

  void _restart(Object? input, {required bool keepDirty}) =>
      _reset(_get(input), keepDirty: keepDirty);

  void _reset(V initial, {required bool keepDirty}) {
    final dirty = isDirty;
    _initial = initial;
    if (keepDirty && dirty) return;
    _value = initial;
    _changed = false;
  }

  void _settle() {
    _initial = _value;
    _changed = false;
  }

  void _dispose() {}
}

/// A field of an action's form typed as `String`, `int`, `double` or `num` (or nullable), with the
/// [controller] of the `TextField` that edits it (since 0.8.1).
final class ActionTextField<V> extends ActionField<V> {
  ActionTextField._(
    ActionForm<Object?, Object?, Record> form,
    String name,
    V Function(Object? input) get,
    V initial,
    this._codec,
  ) : super._(form, name, get, initial) {
    controller = TextEditingController(text: _codec.format(initial));
    _text = controller.text;
    controller.addListener(_onText);
  }

  final FieldCodec<V> _codec;

  /// The controller of the `TextField` that edits this field; the form owns and disposes it.
  late final TextEditingController controller;

  String _text = '';
  String? _parse;
  bool _quiet = false;

  @override
  String? get _parseError => _parse;

  @override
  bool get isDirty => _parse != null || super.isDirty;

  void _onText() {
    if (_quiet || controller.text == _text) return; // a selection change
    _text = controller.text;
    final parsed = _codec.parse(_text, _form._messages);
    _parse = parsed.error;
    if (parsed.error == null) _value = parsed.value as V;
    _changed = true;
    _form._fieldChanged(this);
  }

  @override
  void didChange(V? value) {
    if (value is! V) return;
    _show(value);
    super.didChange(value);
  }

  @override
  bool get _drafted => true;

  @override
  Object? _draftValue() => controller.text;

  @override
  void _restoreDraft(Object? saved) {
    final text = saved! as String;
    _quiet = true;
    try {
      controller.text = text;
    } finally {
      _quiet = false;
    }
    _text = text;
    final parsed = _codec.parse(text, _form._messages);
    _parse = parsed.error;
    if (parsed.error == null) _value = parsed.value as V;
    _changed = isDirty;
  }

  void _show(V value) {
    final text = _codec.format(value);
    _parse = null;
    if (text == controller.text) return;
    _quiet = true;
    try {
      controller.text = text;
      _text = text;
    } finally {
      _quiet = false;
    }
  }

  @override
  void _restart(Object? input, {required bool keepDirty}) =>
      _reset(_get(input), keepDirty: keepDirty);

  @override
  void _reset(V initial, {required bool keepDirty}) {
    final dirty = isDirty;
    super._reset(initial, keepDirty: keepDirty);
    if (!(keepDirty && dirty)) _show(initial);
  }

  @override
  void _dispose() => controller.dispose();
}

/// What the generated `useForm` builds its fields with: one call per field of the action's input
/// [I], in the order the input declares them. An app has no reason to.
final class ActionFormFields<I> {
  ActionFormFields._(this._form, this._initial);

  final ActionForm<Object?, Object?, Record> _form;
  final I _initial;

  /// A text field: [get] reads its initial value from the input, [codec] reads its text.
  ActionTextField<V> text<V>(
    String name,
    V Function(I input) get,
    FieldCodec<V> codec,
  ) => _form._add(
    ActionTextField<V>._(
      _form,
      name,
      (input) => get(input as I),
      get(_initial),
      codec,
    ),
  );

  /// A field of any other type: [get] reads its initial value from the input, and [draft] says how
  /// a draft keeps it (a field with none is not drafted).
  ActionField<V> value<V>(
    String name,
    V Function(I input) get, {
    DraftCodec<V>? draft,
  }) => _form._add(
    ActionField<V>._(
      _form,
      name,
      (input) => get(input as I),
      get(_initial),
      draft,
    ),
  );
}

/// Where one form's draft is kept and what is known of it.
final class _Drafts {
  _Drafts(this.storage, this.key, this.shape, this.config)
    : generation = draftClearGeneration;

  final FutureOr<Storage<String, String>?> storage;
  final String key;
  final String shape;
  final FormDraft config;

  /// The number of clears of every draft when the form started: after another one it writes
  /// nothing (`clearFormDrafts` at sign-out is final for the page that is still open).
  final int generation;

  /// What was last written, to write nothing twice.
  String? lastSaved;

  /// Whether a draft is known to be in the storage.
  bool stored = false;

  /// Runs [body] with the storage, at once when it is there and when it is ready otherwise
  /// (`deferred` is then true). A storage that is null, or fails to open, keeps nothing.
  void use(
    void Function(Storage<String, String> storage, {required bool deferred})
    body,
  ) {
    final s = storage;
    if (s is Future<Storage<String, String>?>) {
      unawaited(
        s.then(
          (opened) {
            if (opened != null) body(opened, deferred: true);
          },
          onError: (Object error, StackTrace _) {
            if (kDebugMode) {
              debugPrint('fespalier_forms: draft storage: $error');
            }
          },
        ),
      );
    } else if (s != null) {
      body(s, deferred: false);
    }
  }
}

void _let(FutureOr<void> done) {
  // The store reports what fails; nobody waits for a draft.
  if (done is Future<void>) unawaited(done);
}

/// The form of an action (since 0.8.1): typed [fields] that start from the route's data, the errors
/// `validate()` and the action give each, and [onSubmit], which is null while the action runs.
///
/// The generated `useForm` makes one for a page and disposes it with the page; it is a
/// [ChangeNotifier] that the page rebuilds on.
final class ActionForm<I, T, F extends Record> extends ChangeNotifier {
  ActionForm._(
    this._action,
    this._initial,
    F Function(ActionFormFields<I> f) build,
    this._input,
    this._validate,
    this._messages,
    this._validation,
    this._resetOnSuccess,
  ) {
    fields = build(ActionFormFields<I>._(this, _initial()));
  }

  ActionNotifier<I, T> Function() _action;
  I Function() _initial;
  final I Function(F fields) _input;
  final Object? Function(I input)? _validate;
  final ActionFormMessages _messages;
  final ActionFormValidation _validation;
  final bool _resetOnSuccess;

  final List<ActionField<Object?>> _all = [];

  /// The fields, one per field of the action's input, typed: `form.fields.amount.controller`.
  late final F fields;

  AsyncValue<T?> _state = const AsyncData<Null>(null);
  bool _submitted = false;
  Map<String, String> _fromAction = const {};
  bool _disposed = false;
  _Drafts? _drafts;

  /// The state of the action, as `useAction`'s `state`.
  AsyncValue<T?> get state => _state;

  /// Whether the action is running: [onSubmit] is null meanwhile.
  bool get isPending => _state.isLoading;

  /// Whether a field differs from what the form started from.
  bool get isDirty => _all.any((f) => f.isDirty);

  /// Whether every field reads as its type and `validate()` has nothing to say of the input.
  bool get isValid =>
      _all.every((f) => f._parseError == null) &&
      _check(_input(fields)).isEmpty;

  /// What failed that is not one field's: the `message` of the action's [FieldErrors] (and the
  /// messages of keys that are no field of the form), or the error of an action that failed
  /// otherwise. Null when the last run did not fail.
  Object? get error => switch (_state) {
    AsyncError(error: final FieldErrors e) => _formLevel(e),
    AsyncError(:final error) => error,
    _ => null,
  };

  String? _formLevel(FieldErrors e) {
    final names = {for (final f in _all) f.name};
    final lines = [
      ?e.message,
      for (final MapEntry(:key, :value) in e.fields.entries)
        if (!names.contains(key)) value,
    ];
    return lines.isEmpty ? null : lines.join('\n');
  }

  /// Runs the action, for `onPressed:`; null while it runs, so the button is disabled.
  VoidCallback? get onSubmit => isPending ? null : _submitQuietly;

  void _submitQuietly() {
    // A sync action stays sync: no Future is made when the action returned a value.
    if (submit() case final Future<T?> pending) unawaited(pending);
  }

  /// Checks the fields, then runs the action with their values. Returns what the action returned
  /// (a value at once for a sync action), or null when a field is wrong or the action failed: the
  /// messages are on the fields, the rest in [error].
  FutureOr<T?> submit() {
    _submitted = true;
    _fromAction = const {};
    if (_all.any((f) => f._parseError != null)) {
      notifyListeners();
      return null;
    }
    final input = _input(fields);
    if (!_check(input).isEmpty) {
      notifyListeners();
      return null;
    }
    final FutureOr<T> result;
    try {
      result = _action().call(input);
    } catch (error) {
      _failed(error);
      return null;
    }
    if (result is! Future<T>) {
      _succeeded();
      return result;
    }
    return result.then<T?>(
      (value) {
        _succeeded();
        return value;
      },
      onError: (Object error) {
        _failed(error);
        return null;
      },
    );
  }

  /// Back to the values the form started from (from the data it was last given), with no errors,
  /// and the action back to idle.
  void reset() {
    _restart(_initial(), keepDirty: false);
    _submitted = false;
    _fromAction = const {};
    _action().reset();
    _clearDraft();
    notifyListeners();
  }

  // ---- drafts ------------------------------------------------------------------------------

  /// What a draft keeps: the fields that changed, that a draft can keep and that are not excluded,
  /// by name. Text is the raw text, so text that does not parse survives.
  Map<String, Object?> _draftFields() => {
    for (final f in _all)
      if (f._drafted && f.isDirty && !_drafts!.config.exclude.contains(f.name))
        f.name: f._draftValue(),
  };

  /// Writes the draft of what the form holds now, or deletes it when nothing of it changed.
  void _saveDraft() {
    final drafts = _drafts;
    if (drafts == null) return;
    final fields = _draftFields();
    if (fields.isEmpty) {
      if (drafts.stored) _clearDraft();
      return;
    }
    if (drafts.generation != draftClearGeneration) return;
    final text = jsonEncode(fields);
    if (text == drafts.lastSaved) return;
    // What is known of the storage changes now, whenever the storage answers.
    drafts
      ..lastSaved = text
      ..stored = true;
    drafts.use((storage, {required deferred}) {
      _let(
        saveDraft(
          storage,
          drafts.key,
          drafts.shape,
          drafts.config.maxAge,
          fields,
          generation: drafts.generation,
        ),
      );
    });
  }

  void _clearDraft() {
    final drafts = _drafts;
    if (drafts == null) return;
    drafts.lastSaved = null;
    drafts.stored = false;
    drafts.use(
      (storage, {required deferred}) => _let(removeDraft(storage, drafts.key)),
    );
  }

  /// Puts what a draft kept into the fields the user has not touched. Silent when the storage
  /// answers at once (the page is building); the page is told when it answers later. A draft that
  /// arrives while the action runs is skipped, not kept for later.
  void _restoreDraft() {
    final drafts = _drafts!;
    assert(() {
      final names = {for (final f in _all) f.name};
      final unknown = drafts.config.exclude.difference(names);
      if (unknown.isNotEmpty) {
        throw FlutterError(
          'FormDraft(exclude: $unknown) names no field of the form (its fields are '
          '${names.join(', ')}): a field that is misspelled here is written to the draft.',
        );
      }
      for (final name in names) {
        if (RegExp(
              'password|passcode|secret|cvv|^pin|^otp',
              caseSensitive: false,
            ).hasMatch(name) &&
            !drafts.config.exclude.contains(name)) {
          debugPrint(
            'fespalier_forms: the field `$name` is kept in the draft; add it to '
            'FormDraft(exclude:) if it must not reach the disk.',
          );
        }
      }
      return true;
    }());
    drafts.use((storage, {required deferred}) {
      void apply(Map<String, Object?>? saved, {required bool deferred}) {
        if (saved == null || _disposed || isPending) return;
        for (final f in _all) {
          if (!f._drafted || f._changed) continue;
          if (drafts.config.exclude.contains(f.name)) continue;
          if (!saved.containsKey(f.name)) continue;
          try {
            f._restoreDraft(saved[f.name]);
          } on Object catch (error) {
            if (kDebugMode) {
              debugPrint('fespalier_forms: draft of ${f.name} dropped: $error');
            }
          }
        }
        drafts
          ..stored = true
          ..lastSaved = jsonEncode(_draftFields());
        _checked = null; // validate() said it of the values from before
        if (deferred) notifyListeners();
      }

      final loaded = loadDraft(storage, drafts.key, drafts.shape);
      if (loaded is Future<Map<String, Object?>?>) {
        unawaited(loaded.then((saved) => apply(saved, deferred: true)));
      } else {
        apply(loaded, deferred: deferred);
      }
    });
  }

  void _restart(I input, {required bool keepDirty}) {
    _checked = null;
    for (final f in _all) {
      f._restart(input, keepDirty: keepDirty);
    }
  }

  // What validate() said of the fields as they are; cleared when one changes.
  FieldErrors? _checked;

  FieldErrors _check(I input) => _checked ??=
      _validate?.call(input) as FieldErrors? ?? const FieldErrors({});

  void _succeeded() {
    // Even when the page is gone: what was kept has been sent.
    _clearDraft();
    if (_disposed) return;
    _submitted = false;
    if (_resetOnSuccess) {
      _restart(_initial(), keepDirty: false);
    } else {
      for (final f in _all) {
        f._settle();
      }
    }
    notifyListeners();
  }

  void _failed(Object error) {
    if (_disposed) return;
    if (error is FieldErrors) _fromAction = error.fields;
    notifyListeners();
  }

  X _add<X extends ActionField<Object?>>(X field) {
    _all.add(field);
    return field;
  }

  void _fieldChanged(ActionField<Object?> field) {
    _checked = null;
    if (_fromAction.containsKey(field.name)) {
      _fromAction = {..._fromAction}..remove(field.name);
    }
    notifyListeners();
  }

  String? _errorOf(ActionField<Object?> field) {
    if (field._parseError case final e? when _shows(field)) return e;
    if (_fromAction[field.name] case final e?) return e;
    if (!_shows(field)) return null;
    return _check(_input(fields)).fields[field.name];
  }

  bool _shows(ActionField<Object?> field) =>
      _submitted ||
      (_validation == ActionFormValidation.onChange && field._changed);

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (!_disposed && _drafts != null) {
      // A form that was left alone keeps nothing; one that changed keeps what changed.
      if (isDirty) {
        _saveDraft();
      } else if (_drafts!.stored) {
        _clearDraft();
      }
    }
    _disposed = true;
    for (final f in _all) {
      f._dispose();
    }
    super.dispose();
  }
}

/// The hook the generated `useForm` is: an [ActionForm] for [action] that lives as long as the
/// widget (a `HookConsumerWidget`), rebuilt when it changes. When [data] is another object than at
/// the last build (the route's data loaded again), the fields the user has not changed take their
/// values from it.
///
/// With a [draft], what the user changed is kept in `formDraftStorage` under [id] (the action's
/// file and name), [key] (its family key) and the `formDraftScope`, and put back when the form is
/// built again (since 0.11.0); [shape] is the form's fields and types, so a form that changed drops
/// the drafts of the old one. The draft, like the storage, is read once, when the form starts.
ActionForm<I, T, F> useActionForm<I, T, F extends Record>(
  WidgetRef ref,
  ActionProvider<I, T> action, {
  required Object? data,
  required I Function() initial,
  required F Function(ActionFormFields<I> f) fields,
  required I Function(F fields) input,
  FieldErrors? Function(I input)? validate,
  ActionFormValidation validation = ActionFormValidation.afterSubmit,
  bool resetOnSuccess = false,
  ActionFormMessages messages = const ActionFormMessages(),
  String id = '',
  List<Object?> key = const [],
  String shape = '',
  FormDraft? draft,
}) {
  assert(
    draft == null || id.isNotEmpty,
    'a form with a draft needs an `id` (the generated useForm passes the action file and name): '
    'without one every such form shares one draft',
  );
  // Built once, when the form starts: the key, the storage and the scope are not read again.
  final _Drafts Function()? drafts = draft == null
      ? null
      : () => _Drafts(
          ref.read(formDraftStorage),
          draftKey(id, key, ref.read(formDraftScope)),
          shape,
          draft,
        );
  return use(
    _ActionFormHook<I, T, F>(
      () => ref.read(action.notifier),
      ref.watch(action),
      data,
      initial,
      fields,
      input,
      validate,
      validation,
      resetOnSuccess,
      messages,
      drafts,
      keys: [action],
    ),
  );
}

final class _ActionFormHook<I, T, F extends Record>
    extends Hook<ActionForm<I, T, F>> {
  const _ActionFormHook(
    this.action,
    this.state,
    this.data,
    this.initial,
    this.fields,
    this.input,
    this.validate,
    this.validation,
    this.resetOnSuccess,
    this.messages,
    this.drafts, {
    super.keys,
  });

  final ActionNotifier<I, T> Function() action;
  final AsyncValue<T?> state;
  final Object? data;
  final I Function() initial;
  final F Function(ActionFormFields<I> f) fields;
  final I Function(F fields) input;
  final FieldErrors? Function(I input)? validate;
  final ActionFormValidation validation;
  final bool resetOnSuccess;
  final ActionFormMessages messages;
  final _Drafts Function()? drafts;

  @override
  _ActionFormState<I, T, F> createState() => _ActionFormState<I, T, F>();
}

final class _ActionFormState<I, T, F extends Record>
    extends HookState<ActionForm<I, T, F>, _ActionFormHook<I, T, F>> {
  late final ActionForm<I, T, F> _form = ActionForm<I, T, F>._(
    hook.action,
    hook.initial,
    hook.fields,
    hook.input,
    hook.validate,
    hook.messages,
    hook.validation,
    hook.resetOnSuccess,
  );

  /// The data the fields last started from.
  late Object? _data = hook.data;

  AppLifecycleListener? _lifecycle;

  @override
  void initHook() {
    _form
      .._state = hook.state
      ..addListener(_changed);
    if (hook.drafts case final make?) {
      _form._drafts = make();
      _form._restoreDraft();
      // A draft is also kept when the app goes to the background: it may never come back.
      _lifecycle = AppLifecycleListener(
        onStateChange: (state) {
          if (state
              case AppLifecycleState.paused ||
                  AppLifecycleState.hidden ||
                  AppLifecycleState.detached) {
            _form._saveDraft();
          }
        },
      );
    }
  }

  void _changed() => setState(() {});

  @override
  void didUpdateHook(_ActionFormHook<I, T, F> oldHook) {
    _form
      .._action = hook.action
      .._initial = hook.initial
      .._state = hook.state;
    // While the action runs, the data the page gets is its own optimistic() guess, which a
    // failure takes back: the fields keep what they have until the write is over.
    if (!_form.isPending && !identical(_data, hook.data)) {
      _data = hook.data;
      // New data: the fields the user left alone follow it, the others keep what they typed.
      _form._restart(hook.initial(), keepDirty: true);
    }
  }

  @override
  ActionForm<I, T, F> build(BuildContext context) => _form;

  @override
  void dispose() {
    _lifecycle?.dispose();
    _form.dispose();
  }
}
