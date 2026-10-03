#!/usr/bin/env python3
"""Sends a seeded, reproducible session of fespalier telemetry to a collector (OTLP/JSON over HTTP).

The spans and logs use only the names in the conventions (scripts/telemetry/conventions_v1.txt);
scripts/test_telemetry.py checks that. `expected()` is what each count panel must show for the
seed, which the smoke test (smoke.py) compares with both backends.

    python3 scripts/telemetry/seed.py [--endpoint http://localhost:4318] [--service shop] [--expected]
"""

import argparse
import json
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
        return {
            "navigation/views": count(
                both(navigate, is_("fespalier.navigation.outcome", "ok"), not_("fespalier.navigation.kind", "refresh"))
            ),
            "navigation/redirected": count(both(navigate, is_("fespalier.navigation.redirected", True))),
            "navigation/not_found": count(both(navigate, is_("fespalier.navigation.outcome", "not_found"))),
            "guards/decisions": count(op("guard", "redirect")),
            "guards/denials": count(both(op("guard"), is_("fespalier.guard.decision", "redirect"))),
            "guards/guard_errors": count(both(op("guard", "redirect"), is_("fespalier.guard.decision", "error"))),
            "data/loads": count(op("data")),
            "data/data_errors": count(both(op("data"), is_("fespalier.data.state", "error"))),
            "data/abandoned": count(both(op("data"), is_("fespalier.data.state", "disposed"))),
            "actions/runs": count(op("action")),
            "actions/failures": count(both(op("action"), is_("fespalier.action.result", "error"))),
            "deferred/deferred_loads": count(op("deferred")),
            "deferred/deferred_failures": count(both(op("deferred"), is_("fespalier.deferred.result", "error"))),
            "errors/failed_spans": count(lambda a: a["_error"]),
            "errors/uncaught": errors,
            "errors/crashes": sum(1 for log in self.logs if log["event"]),
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

    def traces_payload(self):
        return {
            "resourceSpans": [
                {
                    "resource": self.resource(),
                    "scopeSpans": [
                        {"scope": {"name": "fespalier", "version": "0.8.0"}, "spans": [s for s, _ in self.spans]}
                    ],
                }
            ]
        }

    def logs_payload(self):
        return {
            "resourceLogs": [
                {
                    "resource": self.resource(),
                    "scopeLogs": [{"scope": {"name": "otel_zone"}, "logRecords": self.log_records}],
                }
            ]
        }


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
    args = parser.parse_args(argv)
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
