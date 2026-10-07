#!/usr/bin/env python3
"""Sends a seeded, reproducible session of fespalier telemetry to a collector (OTLP/JSON over HTTP).

The spans and logs use only the names in the conventions (packages/fespalier_otel/lib/src/conventions.dart);
scripts/test_telemetry.py checks that. `expected()` is what each count panel must show for the
seed and `rates()` each percentage tile, which the smoke test (smoke.py) compares with both backends.

    python3 scripts/telemetry/seed.py [--endpoint http://localhost:4318] [--service shop] [--expected]

`--showcase` sends a second, hand-shaped session instead (a service called telemetry-example with
amber and red spots, for the docs screenshots; scripts/telemetry/screenshots.mjs). With
`--drip-minutes N` it sends a batch every 15 seconds for N minutes, stamped with the time it is
sent, because Grafana's span metrics are stamped when the collector receives a span.
"""

import argparse
import json
import math
import random
import sys
import time
import urllib.request

SERVICE = "seedshop"
ROUTES = ["/", "/products", "/products/:id", "/cart", "/checkout", "/login", "/docs/*rest"]
GUARD_FILES = [("(members)/guard.dart", "/cart"), ("checkout/guard.dart", "/checkout")]
DATA_FILES = [
    ("products/data.dart", "/products"),
    ("products/$id/data.dart", "/products/:id"),
    ("cart/data.dart", "/cart"),
]
ACTIONS = [("action", "cart/action.dart", "/cart"), ("approve", "orders/$id/action.dart", "/products/:id")]
DEFERRED = [("checkout/page.dart", "/checkout"), ("docs/page.dart", "/docs/*rest")]
ERROR_TYPES = ["StateError", "SocketException", "TimeoutException", "FormatException"]


def value(v):
    if isinstance(v, bool):
        return {"boolValue": v}
    if isinstance(v, int):
        return {"intValue": str(v)}
    return {"stringValue": str(v)}


def attrs(mapping):
    return [{"key": k, "value": value(v)} for k, v in mapping.items() if v is not None]


class Seed:
    def __init__(self, service=SERVICE, seed=1, now=None, navigations=200):
        self.rng = random.Random(seed)
        self.service = service
        self.now = int((time.time() if now is None else now) * 1e9)
        self.spans = []  # (span dict for OTLP, flat attributes for counting)
        self.logs = []
        self._build(navigations)

    def hex(self, n):
        return "".join(self.rng.choice("0123456789abcdef") for _ in range(n))

    def span(self, name, start, duration_ms, trace, parent, attributes, error=None):
        end = start + int(duration_ms * 1e6)
        span = {
            "traceId": trace,
            "spanId": self.hex(16),
            "name": name,
            "kind": 1,
            "startTimeUnixNano": str(start),
            "endTimeUnixNano": str(end),
            "attributes": attrs(attributes),
            "status": {},
        }
        if parent:
            span["parentSpanId"] = parent
        if error:
            span["status"] = {"code": 2, "message": f"{error}: failed"}
            span["events"] = [
                {
                    "timeUnixNano": str(end),
                    "name": "exception",
                    "attributes": attrs({"exception.type": error, "exception.message": "failed"}),
                }
            ]
        flat = dict(attributes, _error=bool(error), _duration_ms=duration_ms)
        self.spans.append((span, flat))
        return span

    def _build(self, navigations):
        rng = self.rng
        # Spread over the last 25 minutes, oldest first.
        clock = self.now - int(25 * 60 * 1e9)
        step = int(25 * 60 * 1e9 / (navigations * 4 + 20))
        kinds = ["go"] * 8 + ["push"] * 5 + ["pop"] * 3 + ["replace"] * 2 + ["refresh"] * 2
        for n in range(navigations):
            clock += step * rng.randint(1, 3)
            trace, root = self.hex(32), None
            kind = "initial" if n == 0 else rng.choice(kinds)
            roll = rng.random()
            attributes = {"fespalier.operation": "navigate", "fespalier.navigation.kind": kind}
            if roll < 0.05:
                attributes["fespalier.navigation.outcome"] = "not_found"
                attributes["fespalier.navigation.redirected"] = False
                name = "navigate (not found)"
            elif roll < 0.09:
                attributes["fespalier.navigation.outcome"] = "superseded"
                attributes["fespalier.navigation.redirected"] = False
                name = "navigate"
            else:
                route = rng.choice(ROUTES)
                redirected = rng.random() < 0.1
                if redirected:
                    route = "/login"
                attributes["fespalier.navigation.outcome"] = "ok"
                attributes["fespalier.navigation.redirected"] = redirected
                attributes["fespalier.route"] = route
                if n:
                    attributes["fespalier.navigation.from"] = rng.choice(ROUTES)
                name = f"navigate {route}"
            duration = round(rng.lognormvariate(3.4, 0.7), 2)
            root_span = self.span(name, clock, duration, trace, None, attributes)
            root = root_span["spanId"]
            route = attributes.get("fespalier.route")
            if rng.random() < 0.55:
                file, guarded = rng.choice(GUARD_FILES)
                decision = rng.choices(["pass", "redirect", "error", "skipped"], [70, 20, 6, 4])[0]
                is_async = rng.random() < 0.4
                error = "StateError" if decision == "error" else None
                self.span(
                    f"guard {file}",
                    clock,
                    round(rng.lognormvariate(2.5, 0.8), 2) if is_async else 0,
                    trace,
                    root,
                    {
                        "fespalier.operation": "guard",
                        "fespalier.route": guarded,
                        "fespalier.file": file,
                        "fespalier.async": is_async,
                        "fespalier.guard.decision": decision,
                        "error.type": error,
                    },
                    error,
                )
            if rng.random() < 0.12:
                file = "old-products/$id/redirect.dart"
                decision = rng.choice(["redirect", "redirect", "error"])
                error = "StateError" if decision == "error" else None
                self.span(
                    f"redirect {file}",
                    clock,
                    1.5,
                    trace,
                    root,
                    {
                        "fespalier.operation": "redirect",
                        "fespalier.route": "/old-products/:id",
                        "fespalier.file": file,
                        "fespalier.async": False,
                        "fespalier.guard.decision": decision,
                        "error.type": error,
                    },
                    error,
                )
            if rng.random() < 0.55:
                file, data_route = rng.choice(DATA_FILES)
                state = rng.choices(["data", "error", "stream", "disposed"], [70, 10, 6, 14])[0]
                is_async = rng.random() < 0.7
                error = rng.choice(ERROR_TYPES) if state == "error" else None
                self.span(
                    f"data {file}",
                    clock,
                    round(rng.lognormvariate(4.0, 0.9), 2) if is_async else 0,
                    trace,
                    root,
                    {
                        "fespalier.operation": "data",
                        "fespalier.route": data_route,
                        "fespalier.file": file,
                        "fespalier.async": is_async,
                        "fespalier.data.state": state,
                        "fespalier.data.keyed": "$id" in file,
                        "error.type": error,
                    },
                    error,
                )
            if rng.random() < 0.14:
                file, deferred_route = rng.choice(DEFERRED)
                error = "DeferredLoadException" if rng.random() < 0.1 else None
                self.span(
                    f"deferred {file}",
                    clock,
                    round(rng.lognormvariate(4.5, 0.6), 2),
                    trace,
                    root,
                    {
                        "fespalier.operation": "deferred",
                        "fespalier.route": deferred_route,
                        "fespalier.file": file,
                        "fespalier.deferred.result": "error" if error else "ok",
                        "error.type": error,
                    },
                    error,
                )
            if rng.random() < 0.16:
                action, file, action_route = rng.choice(ACTIONS)
                error = rng.choice(ERROR_TYPES) if rng.random() < 0.25 else None
                self.span(
                    f"action {file}#{action}",
                    clock,
                    round(rng.lognormvariate(5.0, 0.7), 2),
                    self.hex(32),
                    None,
                    {
                        "fespalier.operation": "action",
                        "fespalier.route": action_route,
                        "fespalier.file": file,
                        "fespalier.async": True,
                        "fespalier.action.name": action,
                        "fespalier.action.result": "error" if error else "ok",
                        "error.type": error,
                    },
                    error,
                )
        self._logs(clock)

    def _logs(self, clock):
        rng = self.rng
        start = clock - int(10 * 60 * 1e9)
        records = []
        # (severityNumber, severityText or None, event.name or None)
        shapes = [(17, "ERROR", None)] * 3 + [(17, None, None)] * 2 + [(21, "FATAL", None)] * 2
        shapes += [(21, "FATAL", "device.crash")] * 2 + [(21, "FATAL", "device.anr")]
        shapes += [(9, "INFO", None)] * 6
        for i, (number, text, event) in enumerate(shapes):
            at = start + i * int(30 * 1e9)
            attributes = {"exception.type": rng.choice(ERROR_TYPES), "exception.message": "boom"}
            if event:
                attributes["event.name"] = event
            record = {
                "timeUnixNano": str(at),
                "severityNumber": number,
                "body": {"stringValue": "uncaught error" if number >= 17 else "a message"},
                "attributes": attrs(attributes),
            }
            if text:
                record["severityText"] = text
            records.append(record)
            self.logs.append({"number": number, "event": event})
        self.log_records = records

    # -- what the panels must show ------------------------------------------------------------

    def count(self, predicate):
        return sum(1 for _, flat in self.spans if predicate(flat))

    def expected(self):
        """The count of every count tile, by "<dashboard>/<panel>"."""

        def op(*names):
            return lambda a: a.get("fespalier.operation") in names

        def both(*preds):
            return lambda a: all(p(a) for p in preds)

        def is_(key, *values):
            return lambda a: a.get(key) in values

        def not_(key, *values):
            return lambda a: a.get(key) not in values

        navigate = op("navigate")
        count = self.count
        errors = sum(1 for log in self.logs if log["number"] >= 17)
        crashes = sum(1 for log in self.logs if log["event"])
        viewed = count(
            both(navigate, is_("fespalier.navigation.outcome", "ok"), not_("fespalier.navigation.kind", "refresh"))
        )
        failed = count(lambda a: a["_error"])
        action_runs = count(op("action"))
        action_failures = count(both(op("action"), is_("fespalier.action.result", "error")))
        return {
            "health/screens_viewed": viewed,
            "health/uncaught": errors,
            "health/crashes": crashes,
            "screens/screens_viewed": viewed,
            "actions/runs": action_runs,
            "actions/failures": action_failures,
            "errors/failed_spans": failed,
            "errors/uncaught": errors,
            "errors/crashes": crashes,
            "errors/guard_errors": count(
                both(op("guard", "redirect"), is_("fespalier.guard.decision", "error"))
            ),
        }

    def rates(self):
        """The percentage of every percentage tile (the seed has enough samples for each)."""

        def share(numerator, denominator):
            return 100.0 * self.count(numerator) / self.count(denominator)

        def op(name):
            return lambda a: a.get("fespalier.operation") == name

        def timed_data(a):
            return op("data")(a) and a.get("fespalier.data.state") in ("data", "error")

        def timed_navigation(a):
            return op("navigate")(a) and a.get("fespalier.navigation.outcome") != "superseded"

        load_failures = share(lambda a: timed_data(a) and a["fespalier.data.state"] == "error", timed_data)
        action_failures = share(lambda a: op("action")(a) and a["_error"], op("action"))
        dead_ends = share(
            lambda a: op("navigate")(a) and a.get("fespalier.navigation.outcome") == "not_found",
            timed_navigation,
        )
        return {
            "health/load_failures": load_failures,
            "health/action_failures": action_failures,
            "actions/action_failures": action_failures,
            "screens/dead_ends": dead_ends,
        }

    def span_count(self):
        """Every span has fespalier.operation, so each one becomes a span metric."""
        return len(self.spans)

    # -- OTLP ---------------------------------------------------------------------------------

    def resource(self):
        return {
            "attributes": attrs(
                {
                    "service.name": self.service,
                    "service.version": "1.0.0",
                    "deployment.environment.name": "development",
                    "fespalier.version": "0.8.0",
                    "fespalier.telemetry.version": "1",
                }
            )
        }

    def traces_payload(self, spans=None):
        spans = [s for s, _ in self.spans] if spans is None else spans
        return {
            "resourceSpans": [
                {
                    "resource": self.resource(),
                    "scopeSpans": [{"scope": {"name": "fespalier", "version": "0.8.0"}, "spans": spans}],
                }
            ]
        }

    def logs_payload(self, records=None):
        records = self.log_records if records is None else records
        return {
            "resourceLogs": [
                {
                    "resource": self.resource(),
                    "scopeLogs": [{"scope": {"name": "otel_zone"}, "logRecords": records}],
                }
            ]
        }


# ---------------------------------------------------------------------------------- showcase

SHOWCASE_SERVICE = "telemetry-example"
SHOWCASE_ROUTES = ["/", "/orders", "/orders/:id", "/settings", "/login"]
# Where a visitor goes from a route: (next route, weight); None ends the visit.
SHOWCASE_FLOW = {
    "/": [("/orders", 60), ("/settings", 15), ("/login", 5), (None, 20)],
    "/orders": [("/orders/:id", 62), ("/", 10), ("/settings", 8), (None, 20)],
    "/orders/:id": [("/orders", 62), ("/orders/:id", 8), ("/", 8), (None, 22)],
    "/settings": [("/", 40), ("/orders", 30), (None, 30)],
    "/login": [("/", 70), (None, 30)],
}
# route -> (median ms, sigma) of the time to the first frame
SHOWCASE_OPEN = {
    "/": (90, 0.45),
    "/orders": (120, 0.45),
    "/orders/:id": (285, 0.5),
    "/settings": (190, 0.48),
    "/login": (70, 0.4),
}


def lognormal(rng, median_ms, sigma):
    return round(rng.lognormvariate(math.log(median_ms), sigma), 2)


class Showcase(Seed):
    """The example app, with its slow and failing spots: what the docs screenshots show.

    A visit is a few navigations a few seconds apart. The middle third of the time has a slow
    spell, so that a time series has a story. Deterministic for a seed (1), like Seed.
    """

    def __init__(self, minutes=6, service=SHOWCASE_SERVICE, seed=1, start=None):
        self.minutes = minutes
        self.start = int((time.time() - minutes * 60 if start is None else start) * 1e9)
        super().__init__(service, seed, now=(self.start / 1e9) + minutes * 60)

    def _pick(self, choices):
        return self.rng.choices([c for c, _ in choices], [w for _, w in choices])[0]

    def _build(self, _):
        rng = self.rng
        window = int(self.minutes * 60 * 1e9)
        visits = int(self.minutes * 18)
        deferred_left, guard_errors_left = 3, 2
        for _visit in range(visits):
            at = self.start + int(rng.random() * window * 0.93)
            route, previous, steps = "/", None, 0
            while route is not None and steps < 14:
                clock = at + int(steps * rng.uniform(1.5, 6.0) * 1e9)
                if clock >= self.start + window:
                    break
                spell = 1.8 if self.start + window / 3 <= clock < self.start + 2 * window / 3 else 1.0
                kind = "initial" if previous is None else self._kind(previous, route)
                target, redirected = route, False
                trace = self.hex(32)
                attributes = {
                    "fespalier.operation": "navigate",
                    "fespalier.navigation.kind": kind,
                    "fespalier.navigation.from": previous,
                }
                roll = rng.random()
                if roll < 0.012:
                    attributes.update(
                        {"fespalier.navigation.outcome": "not_found", "fespalier.navigation.redirected": False}
                    )
                    self.span("navigate (not found)", clock, lognormal(rng, 30, 0.3), trace, None, attributes)
                    previous, route, steps = previous or "/", self._pick(SHOWCASE_FLOW[previous or "/"]), steps + 1
                    continue
                if roll < 0.04:
                    attributes.update(
                        {"fespalier.navigation.outcome": "superseded", "fespalier.navigation.redirected": False}
                    )
                    self.span("navigate", clock, lognormal(rng, 40, 0.4), trace, None, attributes)
                    previous, route, steps = previous or "/", self._pick(SHOWCASE_FLOW[previous or "/"]), steps + 1
                    continue
                guard_decision = None
                if route == "/settings":
                    guard_decision = rng.choices(["pass", "redirect"], [96, 4])[0]
                    if guard_errors_left and rng.random() < 0.04:
                        guard_decision, guard_errors_left = "error", guard_errors_left - 1
                elif route in ("/orders", "/orders/:id") and rng.random() < 0.03:
                    guard_decision = "redirect"
                if guard_decision == "redirect":
                    target, redirected = "/login", True
                median, sigma = SHOWCASE_OPEN[target]
                duration = lognormal(rng, median * spell, sigma)
                attributes.update(
                    {
                        "fespalier.navigation.outcome": "ok",
                        "fespalier.navigation.redirected": redirected,
                        "fespalier.route": target,
                    }
                )
                root = self.span(f"navigate {target}", clock, duration, trace, None, attributes)["spanId"]
                self._children(rng, clock, trace, root, route, target, guard_decision, spell)
                if route == "/settings" and deferred_left and guard_decision != "redirect":
                    deferred_left -= 1
                    self.span(
                        "deferred (tabs)/settings/page.dart",
                        clock,
                        lognormal(rng, 300, 0.25),
                        trace,
                        root,
                        {
                            "fespalier.operation": "deferred",
                            "fespalier.route": "/settings",
                            "fespalier.file": "(tabs)/settings/page.dart",
                            "fespalier.deferred.result": "ok",
                        },
                    )
                previous = target
                route, steps = self._pick(SHOWCASE_FLOW[target]), steps + 1
        self.spans.sort(key=lambda item: int(item[0]["startTimeUnixNano"]))
        self._logs(self.start + window)

    @staticmethod
    def _kind(previous, route):
        if previous == "/orders" and route == "/orders/:id":
            return "push"
        if previous == "/orders/:id" and route == "/orders":
            return "pop"
        if previous == route:
            return "refresh"
        return "go"

    def _children(self, rng, clock, trace, root, route, target, guard_decision, spell):
        if route == "/settings":
            error = "StateError" if guard_decision == "error" else None
            self.span(
                "guard (tabs)/settings/guard.dart",
                clock,
                lognormal(rng, 35, 0.5),
                trace,
                root,
                {
                    "fespalier.operation": "guard",
                    "fespalier.route": "/settings",
                    "fespalier.file": "(tabs)/settings/guard.dart",
                    "fespalier.async": True,
                    "fespalier.guard.decision": guard_decision,
                    "error.type": error,
                },
                error,
            )
        elif route in ("/orders", "/orders/:id"):
            self.span(
                "guard orders/guard.dart",
                clock,
                0.2,
                trace,
                root,
                {
                    "fespalier.operation": "guard",
                    "fespalier.route": route,
                    "fespalier.file": "orders/guard.dart",
                    "fespalier.async": False,
                    "fespalier.guard.decision": guard_decision or "pass",
                },
            )
        if target == "/orders" or target == "/orders/:id":
            keyed = target == "/orders/:id"
            file = "orders/$id/data.dart" if keyed else "orders/data.dart"
            median, sigma = (700, 0.5) if keyed else (300, 0.5)
            state = rng.choices(["data", "error", "disposed"], [95, 2 if keyed else 1, 3])[0]
            error = "SocketException" if state == "error" else None
            self.span(
                f"data {file}",
                clock + int(20e6),
                lognormal(rng, median * (1.3 if spell > 1 else 1), sigma),
                trace,
                root,
                {
                    "fespalier.operation": "data",
                    "fespalier.route": target,
                    "fespalier.file": file,
                    "fespalier.async": True,
                    "fespalier.data.state": state,
                    "fespalier.data.keyed": keyed,
                    "error.type": error,
                },
                error,
            )
        if target == "/orders/:id" and rng.random() < 0.5:
            error = rng.choice(["StateError", "StateError", "TimeoutException"]) if rng.random() < 0.11 else None
            self.span(
                "action orders/$id/action.dart#approve",
                clock + int(2e9),
                lognormal(rng, 450, 0.45),
                self.hex(32),
                None,
                {
                    "fespalier.operation": "action",
                    "fespalier.route": "/orders/:id",
                    "fespalier.file": "orders/$id/action.dart",
                    "fespalier.async": True,
                    "fespalier.action.name": "approve",
                    "fespalier.action.result": "error" if error else "ok",
                    "error.type": error,
                },
                error,
            )
        if target == "/login" and rng.random() < 0.7:
            error = "StateError" if rng.random() < 0.03 else None
            self.span(
                "action login/action.dart#signIn",
                clock + int(3e9),
                lognormal(rng, 300, 0.4),
                self.hex(32),
                None,
                {
                    "fespalier.operation": "action",
                    "fespalier.route": "/login",
                    "fespalier.file": "login/action.dart",
                    "fespalier.async": True,
                    "fespalier.action.name": "signIn",
                    "fespalier.action.result": "error" if error else "ok",
                    "error.type": error,
                },
                error,
            )

    def _logs(self, end):
        # Three uncaught errors, no crash, and a few ordinary records.
        window = end - self.start
        shapes = [(17, "ERROR")] * 3 + [(9, "INFO")] * 5
        self.log_records, self.logs = [], []
        for i, (number, text) in enumerate(shapes):
            at = self.start + int(window * (0.2 + 0.1 * i))
            attributes = {
                "exception.type": "FlutterError",
                "exception.message": "A RenderFlex overflowed by 14 pixels on the bottom.",
            }
            self.log_records.append(
                {
                    "timeUnixNano": str(at),
                    "severityNumber": number,
                    "severityText": text,
                    "body": {"stringValue": "uncaught error" if number >= 17 else "a message"},
                    "attributes": attrs(attributes),
                }
            )
            self.logs.append({"number": number, "event": None})

    def batch(self, until, since=None):
        """The spans and records that start in [since, until) (nanoseconds), as OTLP payloads."""
        spans = [
            s for s, _ in self.spans if (since or 0) <= int(s["startTimeUnixNano"]) < until
        ]
        records = [r for r in self.log_records if (since or 0) <= int(r["timeUnixNano"]) < until]
        return spans, records


def shift(spans, records, delta):
    """The same spans and records, `delta` nanoseconds later (so that a batch ends now)."""
    moved = []
    for span in spans:
        copy = dict(span)
        for key in ("startTimeUnixNano", "endTimeUnixNano"):
            copy[key] = str(int(span[key]) + delta)
        if span.get("events"):
            copy["events"] = [
                {**e, "timeUnixNano": str(int(e["timeUnixNano"]) + delta)} for e in span["events"]
            ]
        moved.append(copy)
    later = [{**r, "timeUnixNano": str(int(r["timeUnixNano"]) + delta)} for r in records]
    return moved, later


def send(endpoint, show, spans, records):
    for path, payload, items in (
        ("/v1/traces", show.traces_payload(spans), spans),
        ("/v1/logs", show.logs_payload(records), records),
    ):
        if items:
            post(endpoint, path, payload)


def run_showcase(endpoint, minutes, drip, interval=15):
    """Sends the showcase session once, or, with `drip`, a batch every `interval` seconds."""
    if not drip:
        show = Showcase(minutes)
        spans, records = show.batch(10**30)
        send(endpoint, show, spans, records)
        print(f"sent {len(spans)} spans and {len(records)} log records for {show.service}")
        return show
    show = Showcase(minutes, start=time.time())
    ticks = max(1, int(minutes * 60 / interval))
    window = int(minutes * 60 * 1e9)
    sent_spans = sent_records = 0
    for tick in range(ticks):
        begin = show.start + int(tick * window / ticks)
        end = show.start + int((tick + 1) * window / ticks)
        pause = end / 1e9 - time.time()
        if pause > 0:
            time.sleep(pause)
        spans, records = show.batch(end, begin)
        spans, records = shift(spans, records, int(time.time() * 1e9) - end)
        send(endpoint, show, spans, records)
        sent_spans += len(spans)
        sent_records += len(records)
        print(f"tick {tick + 1}/{ticks}: {len(spans)} spans", flush=True)
    print(f"sent {sent_spans} spans and {sent_records} log records for {show.service}")
    return show


def post(endpoint, path, payload):
    request = urllib.request.Request(
        endpoint.rstrip("/") + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.status


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--endpoint", default="http://localhost:4318")
    parser.add_argument("--service", default=SERVICE)
    parser.add_argument("--expected", action="store_true", help="print the expected counts, send nothing")
    parser.add_argument("--showcase", action="store_true", help="send the docs screenshots' session instead")
    parser.add_argument("--minutes", type=float, default=6, help="--showcase: how long a session lasts")
    parser.add_argument("--drip-minutes", type=float, help="--showcase: send a batch every 15 s for N minutes")
    args = parser.parse_args(argv)
    if args.drip_minutes and not args.showcase:
        parser.error("--drip-minutes needs --showcase")
    if args.showcase:
        run_showcase(args.endpoint, args.drip_minutes or args.minutes, bool(args.drip_minutes))
        return 0
    seed = Seed(args.service)
    if args.expected:
        print(json.dumps(seed.expected(), indent=2))
        return 0
    for path, payload in (("/v1/traces", seed.traces_payload()), ("/v1/logs", seed.logs_payload())):
        status = post(args.endpoint, path, payload)
        print(f"{path}: HTTP {status}")
    print(f"sent {seed.span_count()} spans and {len(seed.log_records)} log records for {args.service}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
