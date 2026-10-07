# `validate()`, `FieldErrors` and `optimistic()` on `action.dart`

Since 0.8.1 (`cli/src/forms.rs` for the names, `packages/fespalier/lib/src/field_errors.dart` and
`optimistic.dart` for the runtime). These two companions, and the `FieldErrors` they and an action
use, need **only `fespalier`**; the third companion, `form()`, is the `fespalier_forms` package
([`forms.md`](forms.md), since 0.11.0). An app on 0.7.0 or earlier has none of this; one that writes
no companion generates exactly what 0.7.0 did.

**The names.** For the action called `action` a companion is the role itself (`form`, `validate`,
`optimistic`). For any other action, `approve` say, it is `approveForm`, `approveValidate`,
`approveOptimistic`. A companion is **never an action**, even when it takes a `Ref` (that is an
error): an app on 0.7.0 that had an _action_ called `form` beside `action` must rename it.

**`FieldErrors`** (`FieldErrors(fields, message:)`, in core since 0.8.1) is what an action, or
`validate()`, throws or returns to say which fields of its input are wrong: the keys are the names of
the input's fields, `message` is about the input as a whole. Since 0.11.0 it lives in
`packages/fespalier/lib/src/field_errors.dart`, which `fespalier.dart` exports as before, and a form
(`fespalier_forms`) is only one thing that shows it; `fespalier_dio`, `fespalier_auth`,
`fespalier_cratestack` and `fespalier_sentry` use it without one.

## `validate()`: the same check in every path

`FieldErrors? validate(Input input)`: one positional typed parameter (the action's input as
written), no `Ref`, no record needed. It runs in the form, live, **and inside the action's
provider before the action**: `submit`, `useAction`'s `call` and `container.read(...notifier).call`
all go through it. A refused input never starts the write: no loading state, the `FieldErrors` is
thrown synchronously (`call` of the handle returns `null`; `submit` throws), and `state` and
`ActionHandle.fieldErrors` hold it. A check that needs the server belongs in the action:
`throw const FieldErrors({'nickname': 'That nickname is taken'})`. The keys are the record's field
names; `FieldErrors(fields, message:)` also takes a form-level `message`.

## `optimistic()`: the page before the server answers

`T optimistic(T current, Input input)`: two positional typed parameters, returning the first's
type, no `Ref`. It patches **one `data.dart` the action invalidates**, found by the type `T`.

- **The target is searched among what the action invalidates**: this folder's own data first, then
  the sections above it (innermost first), then the rest of `invalidates` in the order listed.
  Nothing of type `T` there is an error (O3a, O3b). So `const invalidates = <Object>[]` beside an
  `optimistic()` is an error, and a custom `invalidates` must list the target. Only the target is
  patched.
- **The sequence.** The patch shows from the start of the write. A failure removes it (the
  rollback). A success keeps it **over the old value until the invalidated data has loaded again**,
  so no frame shows the old value, with `keep_previous: false` too: while a patched write settles,
  `DataView` skips `loading.dart`. Then the server's value shows. A write that is not patched
  shows `loading.dart` as configured.
- **Concurrent writes** apply oldest first; a failure removes only its own patch.
- **Which reads are patched**: `DataView`, `SectionView` (a section's layout and every page
  below it that takes the section's data by type), and the typed `XRoute.watch` /
  `XSection.watch`. **Not patched, the server's value**: `XRoute.data`, `read`, `refresh`,
  `prefetch`, `preload`, `AppRoutes.dataAt`, and `ref.watch(XRoute.data)` anywhere. A
  dependency-triggered reload (`AsyncLoading` with a value) is unpatched in `watch` only.
- **The patch ends with the reload, not with a comparison**: a `data()` that returns the very same
  object after loading still drops it. A patch that throws is reported through
  `FlutterError.reportError` (`while applying an optimistic() patch`) and skipped.
- The page can leave mid-write: the write still finishes and still invalidates.

A form on top of these, with its sample and test, is in [`forms.md`](forms.md).
