// The telemetry conventions, contract version 1 (docs/telemetry-conventions.md, "Telemetry conventions"): every name
// below is a string literal on purpose. A dashboard is built on these, so renaming one must
// fail here before it can ship; adding one is allowed (add its line).
import 'package:fespalier/fespalier.dart' show NavigationSource;
import 'package:fespalier_otel/fespalier_otel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the version of the contract is 1', () {
    expect(FespalierConventions.version, '1');
    expect(FespalierConventions.scope, 'fespalier');
  });

  test('the resource attributes', () {
    expect(FespalierConventions.resourceVersion, 'fespalier.version');
    expect(
      FespalierConventions.resourceTelemetryVersion,
      'fespalier.telemetry.version',
    );
    expect(FespalierOtel.resourceAttributes.keys, [
      'fespalier.version',
      'fespalier.telemetry.version',
    ]);
    expect(
      FespalierOtel.resourceAttributes['fespalier.telemetry.version'],
      '1',
    );
    expect(
      FespalierOtel.resourceAttributes['fespalier.version'],
      matches(RegExp(r'^\d+\.\d+\.\d+')),
    );
  });

  test('the operations', () {
    expect(FespalierConventions.opNavigate, 'navigate');
    expect(FespalierConventions.opGuard, 'guard');
    expect(FespalierConventions.opRedirect, 'redirect');
    expect(FespalierConventions.opData, 'data');
    expect(FespalierConventions.opAction, 'action');
    expect(FespalierConventions.opDeferred, 'deferred');
    expect(FespalierConventions.opAuth, 'auth');
    expect(FespalierConventions.opImage, 'image');
    expect(FespalierConventions.spanNavigateNotFound, 'navigate (not found)');
  });

  test('the attribute keys', () {
    expect(FespalierConventions.operation, 'fespalier.operation');
    expect(FespalierConventions.route, 'fespalier.route');
    expect(FespalierConventions.file, 'fespalier.file');
    expect(FespalierConventions.isAsync, 'fespalier.async');
    expect(FespalierConventions.errorType, 'error.type');
    expect(FespalierConventions.navigationKind, 'fespalier.navigation.kind');
    expect(
      FespalierConventions.navigationOutcome,
      'fespalier.navigation.outcome',
    );
    expect(FespalierConventions.navigationFrom, 'fespalier.navigation.from');
    expect(
      FespalierConventions.navigationRedirected,
      'fespalier.navigation.redirected',
    );
    expect(FespalierConventions.navigationDepth, 'fespalier.navigation.depth');
    expect(FespalierConventions.urlPath, 'url.path');
    expect(FespalierConventions.urlQuery, 'url.query');
    expect(FespalierConventions.guardDecision, 'fespalier.guard.decision');
    expect(FespalierConventions.guardLocation, 'fespalier.guard.location');
    expect(FespalierConventions.dataState, 'fespalier.data.state');
    expect(FespalierConventions.dataKeyed, 'fespalier.data.keyed');
    expect(FespalierConventions.actionName, 'fespalier.action.name');
    expect(FespalierConventions.actionResult, 'fespalier.action.result');
    expect(FespalierConventions.deferredResult, 'fespalier.deferred.result');
    expect(FespalierConventions.pageDuration, 'fespalier.page.duration_ms');
  });

  test('the auth attributes and values (since 0.9.0)', () {
    expect(FespalierConventions.authOperation, 'fespalier.auth.operation');
    expect(FespalierConventions.authResult, 'fespalier.auth.result');
    expect(FespalierConventions.authBackend, 'fespalier.auth.backend');
    expect(FespalierConventions.authTrigger, 'fespalier.auth.trigger');
    expect(FespalierConventions.authDpop, 'fespalier.auth.dpop');
    expect(
      [
        FespalierConventions.authOpRestore,
        FespalierConventions.authOpSignIn,
        FespalierConventions.authOpRefresh,
        FespalierConventions.authOpSignOut,
      ],
      ['restore', 'sign_in', 'refresh', 'sign_out'],
    );
    expect(
      [
        FespalierConventions.authResultOk,
        FespalierConventions.authResultNone,
        FespalierConventions.authResultExpired,
        FespalierConventions.authResultRejected,
        FespalierConventions.authResultCancelled,
        FespalierConventions.authResultError,
      ],
      ['ok', 'none', 'expired', 'rejected', 'cancelled', 'error'],
    );
    expect(
      [
        FespalierConventions.authTriggerExpired,
        FespalierConventions.authTriggerUnauthorized,
        FespalierConventions.authTriggerForced,
      ],
      ['expired', 'unauthorized', 'forced'],
    );
  });

  test('the custom operation (since 0.11.0)', () {
    expect(FespalierConventions.opCustom, 'custom');
    expect(FespalierConventions.customName, 'fespalier.custom.name');
    expect(FespalierConventions.customResult, 'fespalier.custom.result');
  });

  test('the image attributes (since 0.9.0)', () {
    expect(FespalierConventions.imageCdn, 'fespalier.image.cdn');
    expect(FespalierConventions.imageWidth, 'fespalier.image.width');
    expect(FespalierConventions.imagePreload, 'fespalier.image.preload');
    expect(FespalierConventions.imageResult, 'fespalier.image.result');
    expect(FespalierConventions.imageStatus, 'fespalier.image.status');
  });

  test('where a navigation came from (since 0.9.0)', () {
    expect(
      FespalierConventions.navigationSource,
      'fespalier.navigation.source',
    );
    expect(
      [
        FespalierConventions.sourceNotification,
        FespalierConventions.sourceShortcut,
        FespalierConventions.sourceWidget,
        FespalierConventions.sourceLink,
      ],
      ['notification', 'shortcut', 'widget', 'link'],
    );
    // The contract's values are fespalier's NavigationSource, one for one.
    expect(NavigationSource.values, [
      FespalierConventions.sourceNotification,
      FespalierConventions.sourceShortcut,
      FespalierConventions.sourceWidget,
      FespalierConventions.sourceLink,
    ]);
  });

  test('the events', () {
    expect(FespalierConventions.eventEnter, 'fespalier.page.enter');
    expect(FespalierConventions.eventFocus, 'fespalier.page.focus');
    expect(FespalierConventions.eventLeave, 'fespalier.page.leave');
  });

  test('the values of the enum-like attributes', () {
    expect(
      [
        FespalierConventions.kindInitial,
        FespalierConventions.kindGo,
        FespalierConventions.kindPush,
        FespalierConventions.kindPop,
        FespalierConventions.kindReplace,
        FespalierConventions.kindRefresh,
      ],
      ['initial', 'go', 'push', 'pop', 'replace', 'refresh'],
    );
    expect(
      [
        FespalierConventions.outcomeOk,
        FespalierConventions.outcomeNotFound,
        FespalierConventions.outcomeSuperseded,
      ],
      ['ok', 'not_found', 'superseded'],
    );
    expect(
      [
        FespalierConventions.decisionPass,
        FespalierConventions.decisionRedirect,
        FespalierConventions.decisionError,
        FespalierConventions.decisionSkipped,
      ],
      ['pass', 'redirect', 'error', 'skipped'],
    );
    expect(
      [
        FespalierConventions.stateData,
        FespalierConventions.stateError,
        FespalierConventions.stateStream,
        FespalierConventions.stateDisposed,
      ],
      ['data', 'error', 'stream', 'disposed'],
    );
    expect(
      [FespalierConventions.resultOk, FespalierConventions.resultError],
      ['ok', 'error'],
    );
  });
}
