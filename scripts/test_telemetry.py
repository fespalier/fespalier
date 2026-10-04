#!/usr/bin/env python3
"""Checks the telemetry stack's files and dashboards without running any of it.

    python3 scripts/test_telemetry.py            (`just telemetry`, part of `just ci`)

1. The generated dashboards, fields.json and the collector's dimension list are fresh.
2. Every attribute and value a query, a collector dimension or fields.json names is in the telemetry
   conventions (packages/fespalier_otel/lib/src/conventions.dart, read by build_dashboards.py).
3. The OpenObserve and Grafana JSON have the structure each server needs, and the same panels.
4. compose.yaml pins every image by tag and digest, binds ports to loopback, and agrees with
   env.example; `docker compose config` accepts it (skipped without Docker Compose, unless
   FSP_REQUIRE_DOCKER=1, which CI sets: then it fails instead).
5. The dashboards are plain: questions for titles, a description on every panel, one table of
   thresholds that colours both backends and that the README's "Reading the colours" repeats.
6. The dashboard importer, and the report (`fsp telemetry --report`), run against a fake OpenObserve.

A run with Docker is scripts/telemetry/smoke.py (`just telemetry-smoke`).
"""

import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

# Importing import.py would write a .pyc into the stack's template folder, which fsp embeds.
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts/telemetry"))

import build_dashboards as bd  # noqa: E402
import seed as seed_module  # noqa: E402

STACK = ROOT / "cli/templates/telemetry"
COMPOSE = STACK / "compose.yaml"
IMPORTER = STACK / "openobserve/import.py"
REPORT = STACK / "openobserve/report.py"
README = ROOT / "README.md"

print(
    "telemetry conventions: read from packages/fespalier_otel/lib/src/conventions.dart",
    file=sys.stderr,
)


def load(spec_conventions=None):
    conventions = spec_conventions or bd.load_conventions()
    files, dashboards = bd.build(conventions=conventions)
    return conventions, files, dashboards


def oo_files():
    return sorted((STACK / "openobserve/dashboards").glob("*.json"))


def gf_files():
    return sorted((STACK / "grafana/dashboards").glob("*.json"))


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def overlaps(rects):
    for i, a in enumerate(rects):
        for b in rects[i + 1 :]:
            if a["x"] < b["x"] + b["w"] and b["x"] < a["x"] + a["w"] and a["y"] < b["y"] + b["h"] and b["y"] < a["y"] + a["h"]:
                return (a, b)
    return None


class Fresh(unittest.TestCase):
    def test_generated_files_are_fresh(self):
        files, _ = bd.build()
        stale = bd.stale_files(files)
        self.assertEqual([], [str(p.relative_to(ROOT)) for p in stale], bd.STALE)

    def test_a_changed_file_is_stale_and_an_extra_dashboard_too(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "telemetry"
            shutil.copytree(STACK, out)
            files, _ = bd.build(out=out)
            self.assertEqual([], bd.stale_files(files, out))
            target = out / "grafana/dashboards/errors.json"
            target.write_text(target.read_text() + " ")
            (out / "openobserve/dashboards/extra.json").write_text("{}")
            stale = sorted(p.name for p in bd.stale_files(files, out))
            self.assertEqual(["errors.json", "extra.json"], stale)

    def test_four_dashboards_in_both_backends(self):
        self.assertEqual(["actions", "errors", "health", "screens"], [p.stem for p in oo_files()])
        self.assertEqual([p.stem for p in oo_files()], [p.stem for p in gf_files()])
        compose = COMPOSE.read_text()
        self.assertIn("GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH: /etc/fespalier/grafana-dashboards/health.json", compose)
        spec = bd.load_spec()
        homes = [d["id"] for d in spec["dashboard"] if d.get("home")]
        self.assertEqual(["health"], homes)
        self.assertEqual("health", spec["dashboard"][0]["id"])


class Conventions(unittest.TestCase):
    def setUp(self):
        self.conventions, _, self.dashboards = load()

    def test_the_conventions_are_read_from_the_dart_file(self):
        c = self.conventions
        self.assertEqual(
            ["navigate", "guard", "redirect", "data", "action", "deferred", "auth", "image"],
            c.attrs["fespalier.operation"],
        )
        # fespalier_auth's attributes (since 0.9.0): the prefixed constants are values of their own
        # attribute, and the attributes themselves keep their keys.
        self.assertEqual(["restore", "sign_in", "refresh", "sign_out"], c.attrs["fespalier.auth.operation"])
        self.assertEqual(
            ["ok", "none", "expired", "rejected", "cancelled", "error"],
            c.attrs["fespalier.auth.result"],
        )
        self.assertEqual(["expired", "unauthorized", "forced"], c.attrs["fespalier.auth.trigger"])
        self.assertEqual(["true", "false"], c.attrs["fespalier.auth.dpop"])
        self.assertEqual([], c.attrs["fespalier.auth.backend"])
        # fespalier_image's attributes (since 0.9.0): its result shares the generic values, its
        # preload is a boolean, and the width and status are free-form like the navigation depth.
        self.assertEqual(["ok", "error"], c.attrs["fespalier.image.result"])
        self.assertEqual(["true", "false"], c.attrs["fespalier.image.preload"])
        self.assertEqual([], c.attrs["fespalier.image.cdn"])
        self.assertEqual([], c.attrs["fespalier.image.width"])
        self.assertEqual([], c.attrs["fespalier.image.status"])
        self.assertEqual(["ok", "error"], c.attrs["fespalier.action.result"])
        self.assertEqual(["ok", "error"], c.attrs["fespalier.deferred.result"])
        self.assertEqual(["true", "false"], c.attrs["fespalier.async"])
        self.assertEqual([], c.attrs["fespalier.route"])
        self.assertIn("fespalier.telemetry.version", c.resources)
        self.assertIn("service.name", c.resources)
        self.assertIn("fespalier.page.leave", c.events)
        self.assertIn("exception", c.events)
        self.assertIn("fespalier.page.duration_ms", c.event_attrs)
        self.assertNotIn("fespalier.data.attempt", c.attrs)
        self.assertNotIn("fespalier.version", c.attrs)

    def lint(self, text, labels_only=False):
        """The names in a SQL query or PromQL expression that the conventions do not have."""
        known = set(self.conventions.columns) | bd.METRICS | (set() if labels_only else bd.BUILTIN_SQL)
        return sorted(
            n for n in bd.LABEL.findall(text) if n not in known and n not in bd.BUILTIN_SQL
        )

    def values_wrong(self, text, quote):
        """Literals compared with a fespalier column that are not that attribute's values."""
        bad = []
        for column, key in self.conventions.columns.items():
            allowed = set(self.conventions.attrs[key])
            literals = []
            for match in re.finditer(
                rf"\b{column}\s*(?:=~|!~|=|<>|!=)\s*{quote}([^{quote}]*){quote}", text
            ):
                literals += match.group(1).split("|")
            for match in re.finditer(rf"\b{column}\s+IN\s*\(([^)]*)\)", text):
                literals += re.findall(r"'([^']*)'", match.group(1))
            bad += [(column, v) for v in literals if v not in allowed]
        return bad

    def test_sql_names_and_values(self):
        for dash in self.dashboards:
            for panel in dash["panels"]:
                where = f"{dash['id']}/{panel['id']}"
                self.assertEqual([], self.lint(panel["sql"]), where)
                self.assertEqual([], self.values_wrong(panel["sql"], "'"), where)

    def test_promql_names_and_values(self):
        for dash in self.dashboards:
            for panel in dash["panels"]:
                for target in panel["promql"]:
                    where = f"{dash['id']}/{panel['id']}"
                    self.assertEqual([], self.lint(target["expr"], labels_only=True), where)
                    self.assertEqual([], self.values_wrong(target["expr"], '"'), where)

    def test_promql_labels_are_collector_dimensions(self):
        config = (STACK / "collector/config.yaml").read_text(encoding="utf-8")
        listed = re.findall(r"^      - name: (\S+)$", config, re.M)
        self.assertEqual(listed, bd.dimensions(self.dashboards, self.conventions))
        for key in listed:
            self.assertIn(key, self.conventions.attrs)
        for banned in ("url.path", "url.query", "fespalier.guard.location", "fespalier.navigation.from"):
            self.assertNotIn(banned, listed, "a value of the user's, not a dimension")
        for dash in self.dashboards:
            for panel in dash["panels"]:
                for target in panel["promql"]:
                    for label in ("url_path", "fespalier_guard_location"):
                        self.assertNotIn(label, target["expr"])

    def test_label_keys_are_convention_values(self):
        spec = bd.load_spec()
        for name, labels in spec["labels"].items():
            key = self.conventions.columns[f"fespalier_{name}"]
            self.assertEqual(sorted(self.conventions.attrs[key]), sorted(labels), name)

    def test_fields_json_is_in_the_conventions(self):
        fields = read_json(STACK / "openobserve/fields.json")
        known = set(self.conventions.columns) | set(bd.TRACE_COLUMNS)
        self.assertEqual([], [f for f in fields["traces"] if f not in known])
        self.assertEqual(bd.LOG_COLUMNS, fields["logs"])
        # Every column a trace query names is created before the first span arrives.
        for dash in self.dashboards:
            for panel in dash["panels"]:
                if panel["stream_type"] == "traces":
                    for name in bd.LABEL.findall(panel["sql"]):
                        self.assertIn(name, fields["traces"], f"{dash['id']}/{panel['id']}")

    def test_the_seed_uses_only_the_conventions(self):
        seed = seed_module.Seed(now=1_700_000_000)
        for span, _ in seed.spans:
            for attribute in span["attributes"]:
                key = attribute["key"]
                self.assertTrue(key in self.conventions.attrs or key == "error.type", key)
                values = self.conventions.attrs.get(key)
                if values:
                    shown = attribute["value"]
                    text = str(next(iter(shown.values()))).lower()
                    self.assertIn(text, values, key)
            for event in span.get("events", []):
                self.assertIn(event["name"], self.conventions.events)
        resource = {a["key"] for a in seed.resource()["attributes"]}
        self.assertLessEqual(resource, set(self.conventions.resources))


class Structure(unittest.TestCase):
    def setUp(self):
        _, _, self.dashboards = load()

    def test_openobserve_dashboards(self):
        for path in oo_files():
            dash = read_json(path)
            self.assertEqual(8, dash["version"], path.name)
            self.assertEqual(1, len(dash["tabs"]), path.name)
            self.assertTrue(dash["title"].startswith("fespalier · "))
            for key in ("dashboardId", "created", "hash"):
                self.assertNotIn(key, dash)
            panels = dash["tabs"][0]["panels"]
            ids = [p["id"] for p in panels]
            self.assertEqual(len(ids), len(set(ids)), path.name)
            self.assertEqual("service", dash["variables"]["list"][0]["name"])
            rects = []
            for number, panel in enumerate(panels, 1):
                self.assertEqual(1, len(panel["queries"]))
                query = panel["queries"][0]
                self.assertTrue(query["customQuery"])
                self.assertEqual("default", query["fields"]["stream"])
                self.assertIn(query["fields"]["stream_type"], ("traces", "logs"))
                sql = query["query"]
                if panel["type"] == "markdown":
                    self.assertTrue(panel["markdownContent"], panel["id"])
                    self.assertEqual("", sql)
                for axis in ("x", "y", "breakdown"):
                    for item in query["fields"][axis]:
                        alias = item["alias"]
                        self.assertRegex(
                            sql, rf"(?:AS\s+|,\s*|SELECT\s+){alias}\b", f"{path.name} {panel['id']} {alias}"
                        )
                self.assertEqual(number, panel["layout"]["i"])
                rects.append(panel["layout"])
                self.assertLessEqual(panel["layout"]["x"] + panel["layout"]["w"], 192)
            self.assertIsNone(overlaps(rects), path.name)

    def test_grafana_dashboards(self):
        uids = []
        for path in gf_files():
            dash = read_json(path)
            uids.append(dash["uid"])
            self.assertEqual(f"fespalier-{path.stem}", dash["uid"])
            self.assertEqual(bd.DS, dash["templating"]["list"][0]["datasource"])
            ids = [p["id"] for p in dash["panels"]]
            self.assertEqual(len(ids), len(set(ids)))
            rects = []
            for panel in dash["panels"]:
                if panel["type"] == "text":
                    self.assertTrue(panel["options"]["content"], panel["title"])
                    self.assertNotIn("targets", panel)
                    self.assertNotIn("datasource", panel)
                    rects.append(panel["gridPos"])
                    continue
                self.assertEqual(bd.DS, panel["datasource"])
                self.assertTrue(panel["targets"], panel["title"])
                for target in panel["targets"]:
                    self.assertEqual(bd.DS, target["datasource"])
                    self.assertTrue(target["expr"])
                    self.assertNotIn("  ", target["expr"].replace("{{", ""))
                grid = panel["gridPos"]
                self.assertLessEqual(grid["x"] + grid["w"], 24)
                rects.append(grid)
                steps = panel["fieldConfig"]["defaults"]["thresholds"]["steps"]
                colored = panel["fieldConfig"]["defaults"]["color"]["mode"] == "thresholds"
                # Grafana's default thresholds paint a stat red: only a verdict stat is coloured.
                self.assertEqual("green" if colored else "text", steps[0]["color"], panel["title"])
            self.assertIsNone(overlaps(rects), path.name)
        self.assertEqual(len(uids), len(set(uids)))

    def test_both_backends_have_the_same_panels_in_order(self):
        by_id = {d["id"]: d for d in self.dashboards}
        for oo_path, gf_path in zip(oo_files(), gf_files()):
            oo = [p["title"] for p in read_json(oo_path)["tabs"][0]["panels"]]
            gf = [p["title"] for p in read_json(gf_path)["panels"]]
            only_oo = [p["title"] for p in by_id[oo_path.stem]["panels"] if not p["grafana"]]
            self.assertEqual([t for t in oo if t not in only_oo], gf, oo_path.name)
        only_oo = [f"{d['id']}/{p['id']}" for d in self.dashboards for p in d["panels"] if not p["grafana"]]
        self.assertEqual(["health/verdicts", "screens/journeys", "errors/recent_uncaught"], only_oo)

    def test_tables_have_one_grafana_target_per_value_column(self):
        for dash in self.dashboards:
            for panel in dash["panels"]:
                if not panel["grafana"] or panel["type"] == "text":
                    continue
                values = [c for c in panel["columns"] if c["axis"] == "y" and not c.get("oo_only")]
                targets = [t for t in panel["promql"] if not t.get("extra")]
                self.assertEqual(len(values), len(targets), f"{dash['id']}/{panel['id']}")
                if panel["type"] == "stat":
                    self.assertEqual(1, len(panel["promql"]))

    def test_every_sql_column_is_selected_and_nothing_is_left_unexpanded(self):
        for dash in self.dashboards:
            for panel in dash["panels"]:
                for text in [panel["sql"]] + [t["expr"] for t in panel["promql"]]:
                    self.assertNotRegex(text.replace("{{", "").replace("}}", ""), r"\{(?!\})[a-z_0-9:|]+\}")
                if panel["type"] != "text":
                    self.assertIn("$service", panel["sql"])

    def test_drilldowns_name_existing_dashboards(self):
        titles = {d["id"]: d["title"] for d in self.dashboards}
        for path in oo_files():
            for panel in read_json(path)["tabs"][0]["panels"]:
                for drill in panel["config"].get("drilldown", []):
                    self.assertEqual("byDashboard", drill["type"])
                    self.assertEqual("fespalier", drill["data"]["folder"])
                    self.assertIn(drill["data"]["dashboard"], [f"fespalier · {t}" for t in titles.values()])
                    self.assertNotEqual(f"fespalier · {titles[path.stem]}", drill["data"]["dashboard"])
        for path in gf_files():
            for panel in read_json(path)["panels"]:
                text = json.dumps(panel)
                for uid in re.findall(r"/d/(fespalier-[a-z]+)\?", text):
                    self.assertIn(uid, [f"fespalier-{i}" for i in titles])

    def test_percentages_are_not_computed_with_or(self):
        # OpenObserve's PromQL answers nothing for `X or vector(0)` when X is empty (v1.0.4).
        for dash in self.dashboards:
            for panel in dash["panels"]:
                for target in panel["promql"]:
                    self.assertNotRegex(target["expr"], r"\bor\b", f"{dash['id']}/{panel['id']}")
                if panel.get("unit") == "percent":
                    expr = panel["promql"][0]["expr"]
                    self.assertIn("sum_over_time", expr)
                    self.assertRegex(expr, r"^100 \* \(sum\(.*\) - sum\(", f"{dash['id']}/{panel['id']}")

    def test_the_seed_expects_a_count_for_every_count_stat_and_a_rate_for_every_percentage(self):
        seed = seed_module.Seed(now=1_700_000_000)
        counts = {
            f"{d['id']}/{p['id']}"
            for d in self.dashboards
            for p in d["panels"]
            if p["type"] == "stat" and not p.get("unit")
        }
        self.assertEqual(counts, set(seed.expected()))
        rates = {
            f"{d['id']}/{p['id']}"
            for d in self.dashboards
            for p in d["panels"]
            if p["type"] == "stat" and p.get("unit") == "percent"
        }
        self.assertEqual(rates, set(seed.rates()))
        quantiles = {
            f"{d['id']}/{p['id']}"
            for d in self.dashboards
            for p in d["panels"]
            if p["type"] == "stat" and p.get("unit") == "ms"
        }
        self.assertEqual(
            {"health/screens_open", "health/content_loads", "health/actions_finish", "screens/screens_open", "screens/content_loads", "actions/actions_finish"},
            quantiles,
        )

    def test_the_seed_has_enough_samples_for_every_gate(self):
        seed = seed_module.Seed(now=1_700_000_000)
        spec = bd.load_spec()
        minimum = spec["style"]["min_samples"]
        for predicate in (
            lambda a: a["fespalier.operation"] == "navigate" and a.get("fespalier.navigation.outcome") != "superseded",
            lambda a: a["fespalier.operation"] == "data" and a.get("fespalier.data.state") in ("data", "error"),
            lambda a: a["fespalier.operation"] == "action",
        ):
            self.assertGreaterEqual(seed.count(predicate), minimum)


class Plain(unittest.TestCase):
    """The dashboards are written for a developer who does not know metrics."""

    BANNED = ("span", "p50", "p95", "quantile", "attribute", "fespalier_")

    def setUp(self):
        self.spec = bd.load_spec()
        _, _, self.dashboards = load()

    def panels(self):
        for dash in self.dashboards:
            for panel in dash["panels"]:
                yield dash, panel

    def test_every_panel_but_text_has_a_short_description(self):
        for dash, panel in self.panels():
            if panel["type"] == "text":
                continue
            where = f"{dash['id']}/{panel['id']}"
            self.assertTrue(1 <= len(panel["description"]) <= 280, where)
        for path in oo_files():
            for panel in read_json(path)["tabs"][0]["panels"]:
                if panel["type"] != "markdown":
                    self.assertTrue(panel["description"], panel["id"])
        for path in gf_files():
            for panel in read_json(path)["panels"]:
                if panel["type"] != "text":
                    self.assertTrue(panel["description"], panel["title"])

    def test_titles_are_questions_without_jargon(self):
        for dash, panel in self.panels():
            where = f"{dash['id']}/{panel['id']}"
            title = panel["title"]
            if panel["type"] != "text" and panel["id"] != "verdicts":
                self.assertTrue(title.endswith("?"), f"{where}: {title}")
            for word in self.BANNED:
                self.assertNotIn(word, title.lower(), f"{where}: {title}")

    def test_a_verdict_stat_says_what_good_is_and_where_to_look(self):
        names = [d["title"] for d in self.dashboards]
        for dash, panel in self.panels():
            if not panel.get("verdict"):
                continue
            where = f"{dash['id']}/{panel['id']}"
            self.assertIn("Good:", panel["description"], where)
            self.assertTrue(
                re.search(r"\b\w+\.dart\b", panel["description"]) or any(n in panel["description"] for n in names),
                where,
            )

    def test_column_headers_are_words(self):
        for dash, panel in self.panels():
            for column in panel["columns"]:
                label = column["label"]
                where = f"{dash['id']}/{panel['id']}/{column['name']}"
                if panel["type"] in ("text", "stat"):
                    continue
                self.assertNotIn("_", label, where)
                self.assertNotIn("fespalier", label.lower(), where)
        for path in gf_files():
            for panel in read_json(path)["panels"]:
                for transformation in panel.get("transformations", []):
                    for shown in transformation["options"].get("renameByName", {}).values():
                        self.assertNotIn("_", shown, panel["title"])
                        self.assertNotIn("fespalier", shown.lower(), panel["title"])

    def test_the_verdict_table_has_one_question_per_row(self):
        verdicts = next(p for _, p in self.panels() if p["id"] == "verdicts")
        labels = [c["label"] for c in verdicts["columns"] if c["axis"] == "y"]
        self.assertEqual(8, len(labels))
        for label in labels:
            self.assertTrue(label.endswith("?"), label)
        tiles = {p["title"] for _, p in self.panels() if p.get("verdict") or p["id"] in ("dead_ends",)}
        self.assertTrue(set(labels) & tiles)


def threshold_cells(item):
    """The Good, Needs attention and Bad cells of the README's table for one threshold."""
    unit = {"ms": " ms", "percent": " %", "count": ""}[item["unit"]]
    low, high = item["good_below"], item["bad_from"]
    good = f"< {low:g}{unit}" if item["unit"] != "count" else "0"
    if low == high:
        attention = "—"
    elif item["unit"] == "count":
        attention = f"{low:g}–{high - 1:g}"
    else:
        top = high - (0.1 if item["unit"] == "percent" else 1)
        attention = f"{low:g}–{top:g}{unit}"
    bad = f"≥ {high:g}{unit}"
    return [good, attention, bad]


class Verdicts(unittest.TestCase):
    def setUp(self):
        self.spec = bd.load_spec()
        _, _, self.dashboards = load()
        self.style = self.spec["style"]

    def panels(self):
        for dash in self.dashboards:
            for panel in dash["panels"]:
                yield dash, panel

    def test_every_verdict_resolves(self):
        for dash, panel in self.panels():
            where = f"{dash['id']}/{panel['id']}"
            if panel.get("verdict"):
                self.assertIn(panel["verdict"], self.spec["thresholds"], where)
            for tid in panel.get("verdicts", {}).values():
                self.assertIn(tid, self.spec["thresholds"], where)
            if panel.get("marks"):
                self.assertIn(panel["marks"], self.spec["thresholds"], where)

    def test_thresholds_are_ordered_and_explained(self):
        for tid, item in self.spec["thresholds"].items():
            self.assertLessEqual(item["good_below"], item["bad_from"], tid)
            self.assertIn(item["unit"], ("ms", "percent", "count"), tid)
            self.assertTrue(item["why"], tid)

    def numbers(self, tid):
        item = self.spec["thresholds"][tid]
        if item["good_below"] == item["bad_from"]:
            return [0, item["good_below"]]
        return [0, item["good_below"], item["bad_from"]]

    def test_openobserve_stat_mappings_ascend_with_the_thresholds(self):
        colors = [self.style["good"], self.style["attention"], self.style["bad"]]
        for path in oo_files():
            for panel in read_json(path)["tabs"][0]["panels"]:
                mappings = panel["config"].get("mappings")
                stat = panel["type"] == "metric"
                if not stat or not mappings:
                    continue
                values = [float(m["value"]) for m in mappings]
                self.assertEqual(sorted(values), values, panel["id"])
                self.assertTrue(all(m["type"] == "gte" for m in mappings), panel["id"])
                self.assertTrue(all("text" not in m for m in mappings), "a mapping's text replaces the value")
                tid = next(
                    t for d, p in self.panels() for t in [p.get("verdict")]
                    if t and f"panel_{p['id']}" == panel["id"] and d["id"] == path.stem
                )
                self.assertEqual(self.numbers(tid), values, panel["id"])
                expected = colors if len(values) == 3 else [colors[0], colors[2]]
                self.assertEqual(expected, [m["color"] for m in mappings], panel["id"])

    def test_grafana_steps_carry_the_same_numbers(self):
        for dash in self.dashboards:
            gf = {p["title"]: p for p in read_json(STACK / f"grafana/dashboards/{dash['id']}.json")["panels"]}
            for panel in dash["panels"]:
                if not panel["grafana"] or panel["type"] == "text":
                    continue
                shown = gf[panel["title"]]
                if panel.get("verdict"):
                    steps = shown["fieldConfig"]["defaults"]["thresholds"]["steps"]
                    self.assertEqual(self.numbers(panel["verdict"])[1:], [s["value"] for s in steps][1:], panel["id"])
                    self.assertEqual("thresholds", shown["fieldConfig"]["defaults"]["color"]["mode"])
                for column, tid in panel.get("verdicts", {}).items():
                    label = next(c["label"] for c in panel["columns"] if c["name"] == column)
                    override = next(o for o in shown["fieldConfig"]["overrides"] if o["matcher"]["options"] == label)
                    steps = next(x["value"]["steps"] for x in override["properties"] if x["id"] == "thresholds")
                    self.assertEqual(self.numbers(tid)[1:], [s["value"] for s in steps][1:], panel["id"])
                if panel.get("marks"):
                    limits = self.spec["thresholds"][panel["marks"]]
                    steps = shown["fieldConfig"]["defaults"]["thresholds"]["steps"]
                    self.assertEqual([limits["good_below"], limits["bad_from"]], [s["value"] for s in steps][1:])
                    self.assertEqual("dashed", shown["fieldConfig"]["defaults"]["custom"]["thresholdsStyle"]["mode"])

    def test_openobserve_table_cells_carry_the_same_numbers(self):
        for dash in self.dashboards:
            oo = {p["id"]: p for p in read_json(STACK / f"openobserve/dashboards/{dash['id']}.json")["tabs"][0]["panels"]}
            for panel in dash["panels"]:
                for column, tid in panel.get("verdicts", {}).items():
                    shown = oo[f"panel_{panel['id']}"]
                    override = next(o for o in shown["config"]["override_config"] if o["field"]["value"] == column)
                    rules = next(c["rules"] for c in override["config"] if c["type"] == "conditional_styles")
                    self.assertEqual(self.numbers(tid), [r["threshold"] for r in rules], panel["id"])
                    self.assertTrue(all(r["operator"] == ">=" for r in rules))

    def test_the_verdict_sql_contains_each_limit(self):
        verdicts = next(p for _, p in self.panels() if p["id"] == "verdicts")
        for tid in ("screen_open", "content_load", "action_time", "guard_wait", "code_download", "failure_rate", "not_found_rate"):
            item = self.spec["thresholds"][tid]
            self.assertIn(f"< {bd.number(item['good_below'])} THEN", verdicts["sql"], tid)
            self.assertIn(f"< {bd.number(item['bad_from'])} THEN", verdicts["sql"], tid)
        self.assertEqual(8, verdicts["sql"].count(f"< {self.style['min_samples']} THEN '… Too few to judge ("))

    def test_gated_panels_carry_the_gate_in_both_backends(self):
        minimum = self.style["min_samples"]
        for dash, panel in self.panels():
            if not panel.get("gate"):
                continue
            where = f"{dash['id']}/{panel['id']}"
            self.assertIn(f">= {minimum}", panel["sql"], where)
            self.assertIn(f">= {minimum}", panel["promql"][0]["expr"], where)
        for path in oo_files():
            for panel in read_json(path)["tabs"][0]["panels"]:
                if panel["type"] == "metric" and "CASE WHEN" in panel["queries"][0]["query"] and panel["config"].get("mappings"):
                    self.assertEqual(self.style["no_data"], panel["config"]["no_value_replacement"], panel["id"])

    def test_readme_reading_the_colours_matches_the_thresholds(self):
        text = README.read_text(encoding="utf-8")
        section = text.split("#### Reading the colours", 1)[1].split("\n#### ", 1)[0]
        rows = {}
        for line in section.splitlines():
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            found = re.search(r"`([a-z_]+)`", cells[0]) if len(cells) == 5 else None
            if found:
                rows[found.group(1)] = cells
        self.assertEqual(set(self.spec["thresholds"]), set(rows))
        for tid, item in self.spec["thresholds"].items():
            self.assertEqual(threshold_cells(item), rows[tid][1:4], tid)
            self.assertEqual(item["why"], rows[tid][4], tid)
        self.assertIn(f"{self.style['min_samples']} samples", section)


class Compose(unittest.TestCase):
    def docker(self, *words):
        env = {k: v for k, v in os.environ.items() if not k.startswith("FSP_")}
        return subprocess.run(
            ["docker", "compose", "-f", str(COMPOSE), *words], capture_output=True, text=True, env=env
        )

    def need_compose(self):
        try:
            ok = subprocess.run(["docker", "compose", "version"], capture_output=True).returncode == 0
        except OSError:
            ok = False
        if not ok:
            if os.environ.get("FSP_REQUIRE_DOCKER") == "1":
                self.fail("docker compose is required (FSP_REQUIRE_DOCKER=1) and `docker compose version` fails")
            self.skipTest("docker compose is not available: the compose file was not checked by Docker")

    def test_images_are_pinned_by_tag_and_digest(self):
        images = re.findall(r"^\s+image: (\S+)$", COMPOSE.read_text(), re.M)
        self.assertEqual(4, len(images))
        for image in images:
            self.assertRegex(image, r"^[a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$")

    def test_compose_defaults_agree_with_env_example(self):
        text = COMPOSE.read_text()
        defaults = dict(re.findall(r"\$\{(FSP_[A-Z0-9_]+):-([^}]*)\}", text))
        example = {}
        for line in (STACK / "env.example").read_text().splitlines():
            if line and not line.startswith("#"):
                key, _, value = line.partition("=")
                example[key] = value
        self.assertEqual(example, defaults)

    def test_openobserve_default_password_meets_its_policy(self):
        password = dict(re.findall(r"^(FSP_O2_PASSWORD)=(.*)$", (STACK / "env.example").read_text(), re.M))[
            "FSP_O2_PASSWORD"
        ]
        self.assertTrue(8 <= len(password) <= 128)
        for pattern in ("[a-z]", "[A-Z]", "[0-9]", "[^A-Za-z0-9]"):
            self.assertRegex(password, pattern)

    def test_compose_config_is_valid(self):
        self.need_compose()
        for words in (["config", "-q"], ["--profile", "grafana", "config", "-q"]):
            result = self.docker(*words)
            self.assertEqual(0, result.returncode, result.stderr)

    def test_every_published_port_is_on_loopback(self):
        self.need_compose()
        result = self.docker("--profile", "grafana", "config", "--format", "json")
        self.assertEqual(0, result.returncode, result.stderr)
        config = json.loads(result.stdout)
        self.assertEqual({"collector", "openobserve", "dashboards", "grafana"}, set(config["services"]))
        for name, service in config["services"].items():
            for port in service.get("ports", []):
                self.assertEqual("127.0.0.1", port["host_ip"], f"{name} {port}")
        self.assertEqual("no", config["services"]["dashboards"]["restart"])

    def test_the_lan_override_moves_only_the_otlp_ports(self):
        self.need_compose()
        env = dict(os.environ, FSP_OTLP_BIND="0.0.0.0")
        result = subprocess.run(
            ["docker", "compose", "-f", str(COMPOSE), "--profile", "grafana", "config", "--format", "json"],
            capture_output=True, text=True, env=env,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        services = json.loads(result.stdout)["services"]
        self.assertEqual({"0.0.0.0"}, {p["host_ip"] for p in services["collector"]["ports"]})
        self.assertEqual({"127.0.0.1"}, {p["host_ip"] for p in services["openobserve"]["ports"]})
        self.assertEqual({"127.0.0.1"}, {p["host_ip"] for p in services["grafana"]["ports"]})


# ----------------------------------------------------------------------------------------- importer


class FakeOpenObserve:
    """Just the endpoints import.py uses, as v1.0.4 answers them (checked against the real server)."""

    def __init__(self, not_ready_polls=0):
        self.not_ready_polls = not_ready_polls
        self.schema_status = 200
        self.streams = {}  # type -> list of field names
        self.folders = {}  # name -> id
        self.dashboards = {}  # id -> {"title", "hash", "body"}
        self.requests = []
        self.counter = 1000

    def next_id(self):
        self.counter += 1
        return str(self.counter)

    def writes(self):
        return [r for r in self.requests if r[0] in ("POST", "PUT", "DELETE")]


def make_handler(fake):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body):
            raw = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def handle_any(self, method):
            url = urlparse(self.path)
            query = parse_qs(url.query)
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length)) if length else None
            fake.requests.append((method, url.path, url.query, body))
            if not self.headers.get("Authorization", "").startswith("Basic "):
                return self.reply(401, {"code": 401, "message": "Unauthorized"})
            path = url.path
            if path == "/api/default/dashboards" and method == "GET" and "folder" not in query:
                if fake.not_ready_polls > 0:
                    fake.not_ready_polls -= 1
                    return self.reply(503, {"code": 503, "message": "starting"})
                return self.reply(200, {"dashboards": []})
            if path == "/api/default/dashboards" and method == "GET":
                folder = query["folder"][0]
                items = [
                    {"title": d["title"], "hash": d["hash"], "dashboard_id": i, "folder_id": folder}
                    for i, d in fake.dashboards.items()
                ]
                return self.reply(200, {"dashboards": items})
            if path == "/api/default/dashboards" and method == "POST":
                new_id, new_hash = fake.next_id(), fake.next_id()
                fake.dashboards[new_id] = {"title": body["title"], "hash": new_hash, "body": body}
                return self.reply(200, {"v8": body, "version": 8, "hash": new_hash})
            match = re.fullmatch(r"/api/default/dashboards/(\d+)", path)
            if match and method == "DELETE":
                if match.group(1) not in fake.dashboards:
                    return self.reply(404, {"code": 404, "message": "Not found"})
                del fake.dashboards[match.group(1)]
                return self.reply(200, {"code": 200, "message": "Dashboard deleted"})
            if match and method == "PUT":
                current = fake.dashboards[match.group(1)]
                if query["hash"][0] != current["hash"]:
                    return self.reply(409, {"code": 409, "message": "Conflict"})
                current["hash"], current["body"] = fake.next_id(), body
                return self.reply(200, {"v8": body, "version": 8, "hash": current["hash"]})
            match = re.fullmatch(r"/api/default/streams/default/schema", path)
            if match and method == "GET":
                kind = query["type"][0]
                if fake.schema_status != 200:
                    return self.reply(fake.schema_status, {"code": fake.schema_status, "message": "broken"})
                if kind not in fake.streams:
                    return self.reply(404, {"code": 404, "message": "stream not found"})
                return self.reply(200, {"schema": [{"name": n, "type": "Utf8"} for n in fake.streams[kind]]})
            if path == "/api/default/streams/default" and method == "POST":
                fake.streams[query["type"][0]] = [f["name"] for f in body["fields"]]
                return self.reply(200, {"code": 200, "message": "stream created"})
            if path == "/api/default/streams/default/settings" and method == "PUT":
                kind = query["type"][0]
                if kind not in fake.streams:
                    return self.reply(404, {"code": 404, "message": "stream not found"})
                fake.streams[kind] += [f["name"] for f in body["fields"]["add"]]
                return self.reply(200, {"code": 200, "message": ""})
            match = re.fullmatch(r"/api/v2/default/folders/dashboards/name/(.+)", path)
            if match and method == "GET":
                if match.group(1) not in fake.folders:
                    return self.reply(404, {"code": 404, "message": "Folder not found"})
                return self.reply(200, {"folderId": fake.folders[match.group(1)], "name": match.group(1)})
            if path == "/api/v2/default/folders/dashboards" and method == "POST":
                fake.folders[body["name"]] = fake.next_id()
                return self.reply(200, {"folderId": fake.folders[body["name"]], "name": body["name"]})
            return self.reply(404, {"code": 404, "message": "no such endpoint"})

        def do_GET(self):
            self.handle_any("GET")

        def do_POST(self):
            self.handle_any("POST")

        def do_PUT(self):
            self.handle_any("PUT")

        def do_DELETE(self):
            self.handle_any("DELETE")

    return Handler


def load_importer():
    spec = importlib.util.spec_from_file_location("fespalier_import", IMPORTER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Importer(unittest.TestCase):
    def setUp(self):
        self.fake = FakeOpenObserve()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.fake))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.server_close)
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.source = self.tmp / "openobserve"
        shutil.copytree(STACK / "openobserve", self.source)
        self.state = self.tmp / "state"
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.fields = json.loads((self.source / "fields.json").read_text())
        titles = [json.loads(p.read_text())["title"] for p in sorted((self.source / "dashboards").glob("*.json"))]
        self.assertEqual(4, len(titles))
        self.titles = titles

    def run_importer(self, **extra):
        env = {
            "FSP_O2_URL": self.url,
            "FSP_O2_EMAIL": "dev@fespalier.local",
            "FSP_O2_PASSWORD": "Fespalier-local-1",
            "FSP_O2_WAIT": "30",
            "FSP_STATE_DIR": str(self.state),
            "FSP_SOURCE_DIR": str(self.source),
            **extra,
        }
        out, code = io.StringIO(), 0
        module = load_importer()
        real_sleep = time.sleep
        with (
            contextlib.redirect_stdout(out),
            unittest.mock.patch.dict(os.environ, env),
            unittest.mock.patch("time.sleep", lambda seconds: real_sleep(min(seconds, 0.01))),
        ):
            try:
                module.main()
            except SystemExit as exit_:
                code = exit_.code
        return code, out.getvalue().splitlines()

    def up_to_date(self):
        return [f"fespalier: {t}: up to date" for t in self.titles]

    def test_a_fresh_install_waits_creates_streams_a_folder_and_four_dashboards(self):
        self.fake.not_ready_polls = 2
        code, lines = self.run_importer()
        self.assertEqual(0, code)
        self.assertEqual(
            [
                f"fespalier: created the traces stream with {len(self.fields['traces'])} fields",
                f"fespalier: created the logs stream with {len(self.fields['logs'])} fields",
            ]
            + [f"fespalier: {t}: created" for t in self.titles],
            lines,
        )
        self.assertEqual(0, self.fake.not_ready_polls)
        self.assertEqual(4, len(self.fake.dashboards))
        posts = [r for r in self.fake.requests if r[0] == "POST" and r[1] == "/api/default/dashboards"]
        self.assertEqual(4, len(posts))
        self.assertTrue(all(f"folder={self.fake.folders['fespalier']}" in r[2] for r in posts))
        self.assertEqual(self.fields["traces"], self.fake.streams["traces"])
        self.assertFalse(list(self.state.glob("*.tmp")), "the state is written atomically")
        saved = json.loads((self.state / "imported.json").read_text())
        self.assertEqual(set(self.titles), set(saved))

    def test_a_second_run_sends_no_write(self):
        self.run_importer()
        before = len(self.fake.writes())
        code, lines = self.run_importer()
        self.assertEqual(0, code)
        self.assertEqual(self.up_to_date(), lines)
        self.assertEqual(before, len(self.fake.writes()))

    def test_a_changed_file_is_updated_with_the_listed_hash(self):
        self.run_importer()
        target = self.source / "dashboards/errors.json"
        dash = json.loads(target.read_text())
        dash["description"] = "changed by a new release"
        target.write_text(json.dumps(dash))
        errors = next(i for i, d in self.fake.dashboards.items() if d["title"] == dash["title"])
        listed = self.fake.dashboards[errors]["hash"]
        code, lines = self.run_importer()
        self.assertEqual(0, code)
        self.assertEqual(
            [f"fespalier: {t}: updated" if t == dash["title"] else f"fespalier: {t}: up to date" for t in self.titles],
            lines,
        )
        puts = [r for r in self.fake.requests if r[0] == "PUT" and "/dashboards/" in r[1]]
        self.assertEqual(1, len(puts))
        self.assertIn(f"hash={listed}", puts[0][2])
        self.assertEqual("changed by a new release", self.fake.dashboards[errors]["body"]["description"])

    def test_a_dashboard_edited_in_openobserve_is_left_alone(self):
        self.run_importer()
        target = self.source / "dashboards/errors.json"
        dash = json.loads(target.read_text())
        errors = next(i for i, d in self.fake.dashboards.items() if d["title"] == dash["title"])
        self.fake.dashboards[errors]["hash"] = "edited-in-the-ui"
        dash["description"] = "changed by a new release"
        target.write_text(json.dumps(dash))
        before = len(self.fake.writes())
        code, lines = self.run_importer()
        self.assertEqual(0, code)
        self.assertIn(
            f"fespalier: {dash['title']}: changed in OpenObserve since fsp telemetry wrote it, left alone; "
            "delete it to get the new version",
            lines,
        )
        self.assertEqual(before, len(self.fake.writes()))

    def test_a_deleted_dashboard_comes_back(self):
        self.run_importer()
        gone = next(iter(self.fake.dashboards))
        title = self.fake.dashboards.pop(gone)["title"]
        code, lines = self.run_importer()
        self.assertEqual(0, code)
        self.assertIn(f"fespalier: {title}: created", lines)

    def old_dashboard(self, title="fespalier · Navigation"):
        """A dashboard an earlier fsp wrote: it is on the server and in the state, but not shipped."""
        self.run_importer()
        new_id, new_hash = self.fake.next_id(), self.fake.next_id()
        self.fake.dashboards[new_id] = {"title": title, "hash": new_hash, "body": {}}
        saved = json.loads((self.state / "imported.json").read_text())
        saved[title] = {"source": "old", "hash": new_hash}
        (self.state / "imported.json").write_text(json.dumps(saved))
        return new_id

    def test_a_dashboard_no_longer_shipped_is_removed(self):
        old = self.old_dashboard()
        code, lines = self.run_importer()
        self.assertEqual(0, code)
        self.assertEqual(
            self.up_to_date() + ["fespalier: fespalier · Navigation: removed (fsp telemetry no longer ships it)"],
            lines,
        )
        self.assertNotIn(old, self.fake.dashboards)
        deletes = [r for r in self.fake.requests if r[0] == "DELETE"]
        self.assertEqual([(f"/api/default/dashboards/{old}", f"folder={self.fake.folders['fespalier']}")], [(r[1], r[2]) for r in deletes])
        self.assertNotIn("fespalier · Navigation", json.loads((self.state / "imported.json").read_text()))
        code, lines = self.run_importer()
        self.assertEqual(self.up_to_date(), lines)

    def test_a_dashboard_no_longer_shipped_but_edited_is_left_alone(self):
        old = self.old_dashboard()
        self.fake.dashboards[old]["hash"] = "edited-in-the-ui"
        code, lines = self.run_importer()
        self.assertEqual(0, code)
        self.assertEqual(
            self.up_to_date()
            + [
                "fespalier: fespalier · Navigation: no longer shipped, but changed in OpenObserve since "
                "fsp telemetry wrote it, left alone; delete it when you are done with it"
            ],
            lines,
        )
        self.assertIn(old, self.fake.dashboards)
        self.assertEqual([], [r for r in self.fake.requests if r[0] == "DELETE"])

    def test_a_dashboard_deleted_by_hand_is_forgotten_quietly(self):
        old = self.old_dashboard()
        del self.fake.dashboards[old]
        code, lines = self.run_importer()
        self.assertEqual(0, code)
        self.assertEqual(self.up_to_date(), lines)
        self.assertNotIn("fespalier · Navigation", json.loads((self.state / "imported.json").read_text()))

    def test_an_existing_stream_gets_only_the_missing_columns(self):
        self.fake.streams["traces"] = self.fields["traces"][:-3]
        self.fake.streams["logs"] = list(self.fields["logs"])
        code, lines = self.run_importer()
        self.assertEqual(0, code)
        self.assertEqual("fespalier: added 3 fields to the traces stream", lines[0])
        puts = [r for r in self.fake.requests if r[0] == "PUT" and "settings" in r[1]]
        self.assertEqual(1, len(puts))
        self.assertEqual(
            [{"name": n, "type": "Utf8"} for n in self.fields["traces"][-3:]], puts[0][3]["fields"]["add"]
        )
        self.assertEqual(self.fields["traces"], self.fake.streams["traces"])

    def test_a_timeout_names_the_url_and_exits_1(self):
        self.server.shutdown()
        self.server.server_close()
        code, lines = self.run_importer(FSP_O2_WAIT="1")
        self.assertEqual(1, code)
        self.assertEqual(1, len(lines))
        self.assertRegex(
            lines[0],
            rf"^fespalier: OpenObserve did not answer at {re.escape(self.url)} within 1s \(.+\)\.$",
        )

    def test_an_unexpected_status_exits_1_with_the_body(self):
        self.fake.schema_status = 500
        code, lines = self.run_importer()
        self.assertEqual(1, code)
        self.assertRegex(lines[-1], r"^fespalier: the traces stream: OpenObserve answered HTTP \d+: ")


# ------------------------------------------------------------------------------------------ report


class FakeSearch(FakeOpenObserve):
    """Adds `_search`, answering from `rows` by a word of the SQL."""

    def __init__(self):
        super().__init__()
        self.apps = ["telemetry-example"]
        self.status = 200
        self.rows = {}
        self.queries = []


def make_report_handler(fake):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body):
            raw = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            self.reply(200, {"dashboards": []})

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length))
            sql = body["query"]["sql"]
            fake.queries.append((urlparse(self.path).query, sql))
            if fake.status != 200:
                return self.reply(fake.status, {"code": fake.status, "message": "boom"})
            if sql.startswith("SELECT DISTINCT service_name"):
                return self.reply(200, {"hits": [{"app": a} for a in fake.apps]})
            for word, rows in fake.rows.items():
                if word in sql:
                    return self.reply(200, {"hits": rows})
            return self.reply(200, {"hits": []})

    return Handler


class Report(unittest.TestCase):
    VERDICTS = {
        "app": "This app",
        "screens_open": "✓ Good · 240 ms",
        "content_loads": "! Needs attention · 1.4 s",
        "actions_finish": "✓ Good · 310 ms",
        "guard_wait": "✓ Good · 60 ms",
        "code_download": "… Too few to judge (4)",
        "load_failures": "! Needs attention · 2.5 %",
        "action_failures": "✗ Bad · 6.2 %",
        "dead_ends": "✓ Good · 0.4 %",
    }

    def setUp(self):
        self.fake = FakeSearch()
        self.fake.rows = {
            "AS screens_open": [self.VERDICTS],
            "AS open_p95": [{"route": "/orders/:id", "views": 412, "open_p95": 1234.5, "content_p95": 2301.0}],
            "AS type": [
                {"operation": "action", "file": "orders/$id/action.dart", "route": "/orders/:id", "type": "StateError", "n": 3}
            ],
            "AS uncaught": [{"uncaught": 0}],
            "AS crashes": [{"crashes": 0}],
        }
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_report_handler(self.fake))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.server_close)
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.source = self.tmp / "openobserve"
        shutil.copytree(STACK / "openobserve", self.source)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def run_report(self):
        env = {
            "FSP_O2_URL": self.url,
            "FSP_O2_EMAIL": "dev@fespalier.local",
            "FSP_O2_PASSWORD": "Fespalier-local-1",
            "FSP_O2_PORT": "5080",
            "FSP_SOURCE_DIR": str(self.source),
        }
        spec = importlib.util.spec_from_file_location("fespalier_report", REPORT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        out, code = io.StringIO(), 0
        with contextlib.redirect_stdout(out), unittest.mock.patch.dict(os.environ, env):
            try:
                module.main()
            except SystemExit as exit_:
                code = exit_.code
        return code, out.getvalue()

    def test_the_report_for_one_app(self):
        code, text = self.run_report()
        self.assertEqual(0, code)
        self.assertEqual(
            "\n".join(
                [
                    "fespalier · telemetry-example · last hour",
                    "  ✓ good               Do screens open quickly?                     240 ms",
                    "  ! needs attention    Does content load quickly?                   1.4 s",
                    "  ✓ good               Do actions finish quickly?                   310 ms",
                    "  ✓ good               Do checks slow screens down?                 60 ms",
                    "  … too few to judge   Does a deferred page's code arrive quickly?  4 samples",
                    "  ! needs attention    How often does content fail to load?         2.5 %",
                    "  ✗ bad                How often do actions fail?                   6.2 %",
                    "  ✓ good               How often does a link lead nowhere?          0.4 %",
                    "  ✓ good               Did anything throw an uncaught error?        none",
                    "  ✓ good               Did the app crash or freeze?                 none",
                    "  Slowest screen: /orders/:id, 1.2 s to open and 2.3 s for its content (slowest 5 %, 412 views)",
                    "  Fails most: Action (action.dart) orders/$id/action.dart on /orders/:id, 3 × StateError",
                    "  Details: http://localhost:5080, Dashboards, folder fespalier, fespalier · App health",
                ]
            )
            + "\n",
            text,
        )

    def test_the_sql_is_the_dashboards_own(self):
        self.run_report()
        health = {p["id"]: p for p in read_json(STACK / "openobserve/dashboards/health.json")["tabs"][0]["panels"]}
        sent = {sql for _, sql in self.fake.queries}
        for panel in ("verdicts", "slowest_screens", "top_failures", "uncaught", "crashes"):
            sql = health[f"panel_{panel}"]["queries"][0]["query"].replace("$service", "telemetry-example")
            self.assertIn(sql, sent, panel)
        kinds = {sql: query for query, sql in self.fake.queries}
        self.assertTrue(any("type=logs" in q for q in kinds.values()))

    def test_counts_show_a_number_and_the_grade_of_their_thresholds(self):
        self.fake.rows["AS uncaught"] = [{"uncaught": 3}]
        self.fake.rows["AS crashes"] = [{"crashes": 1}]
        code, text = self.run_report()
        self.assertEqual(0, code)
        lines = text.splitlines()
        self.assertRegex(lines[9], r"^  ! needs attention    Did anything throw an uncaught error\? +3$")
        self.assertRegex(lines[10], r"^  ✗ bad                Did the app crash or freeze\? +1$")

    def test_nothing_failed(self):
        self.fake.rows["AS type"] = []
        _, text = self.run_report()
        self.assertIn("\n  Nothing failed.\n", text)
        self.assertNotIn("Fails most", text)

    def test_the_slowest_screen_without_content(self):
        self.fake.rows["AS open_p95"] = [{"route": "/", "views": 1, "open_p95": 80.2, "content_p95": None}]
        _, text = self.run_report()
        self.assertIn("  Slowest screen: /, 80 ms to open (slowest 5 %, 1 view)\n", text)

    def test_two_apps_are_two_blocks_separated_by_a_blank_line(self):
        self.fake.apps = ["a", "b"]
        _, text = self.run_report()
        blocks = text.rstrip("\n").split("\n\n")
        self.assertEqual(["fespalier · a · last hour", "fespalier · b · last hour"], [b.splitlines()[0] for b in blocks])

    def test_no_apps_says_so_and_succeeds(self):
        self.fake.apps = []
        code, text = self.run_report()
        self.assertEqual(0, code)
        self.assertEqual(
            "no fespalier spans in the last hour: is the app running, with telemetry: true and FespalierOtel "
            'installed? (README, "Telemetry")\n',
            text,
        )

    def test_an_error_from_openobserve_exits_1(self):
        self.fake.status = 500
        code, text = self.run_report()
        self.assertEqual(1, code)
        self.assertRegex(text, r"^fespalier: the report's query failed: HTTP 500: ")


if __name__ == "__main__":
    unittest.main(verbosity=1)
