#!/usr/bin/env python3
"""Checks the telemetry stack's files and dashboards without running any of it.

    python3 scripts/test_telemetry.py            (`just telemetry`, part of `just ci`)

1. The generated dashboards, fields.json and the collector's dimension list are fresh.
2. Every attribute and value a query, a collector dimension or fields.json names is in the telemetry
   conventions (scripts/telemetry/conventions_v1.txt, a copy of contract v1 until
   packages/fespalier_otel's conventions.dart is on main).
3. The OpenObserve and Grafana JSON have the structure each server needs, and the same panels.
4. compose.yaml pins every image by tag and digest, binds ports to loopback, and agrees with
   env.example; `docker compose config` accepts it (skipped without Docker Compose, unless
   FSP_REQUIRE_DOCKER=1, which CI sets: then it fails instead).
5. The dashboard importer, run against a fake OpenObserve.

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

print(
    "telemetry conventions: read from scripts/telemetry/conventions_v1.txt "
    "(a copy of contract v1; the source of truth will be packages/fespalier_otel's conventions.dart)",
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
            target = out / "grafana/dashboards/guards.json"
            target.write_text(target.read_text() + " ")
            (out / "openobserve/dashboards/extra.json").write_text("{}")
            stale = sorted(p.name for p in bd.stale_files(files, out))
            self.assertEqual(["extra.json", "guards.json"], stale)

    def test_six_dashboards_in_both_backends(self):
        self.assertEqual(
            ["actions", "data", "deferred", "errors", "guards", "navigation"],
            [p.stem for p in oo_files()],
        )
        self.assertEqual([p.stem for p in oo_files()], [p.stem for p in gf_files()])


class Conventions(unittest.TestCase):
    def setUp(self):
        self.conventions, _, self.dashboards = load()

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

    def test_every_new_name_in_the_spec_is_declared_in_requires(self):
        maximal = bd.load_conventions()
        proposed = set()
        with open(bd.SPEC, "rb") as handle:
            spec = bd.tomllib.load(handle)
        for dash in spec["dashboard"]:
            for panel in dash["panels"]:
                proposed |= set(panel.get("requires", []))
                for item in panel.get("columns", []) + panel.get("promql", []):
                    proposed |= set(item.get("requires", []))
        self.assertTrue(proposed)
        for key in proposed:
            self.assertNotIn(key, maximal.attrs, f"{key} is in the conventions now: drop its `requires`")
            maximal.attrs[key] = []
            maximal.columns[key.replace(".", "_")] = key
        _, _, full = load(maximal)
        for dash in full:
            for panel in dash["panels"]:
                texts = [panel["sql"]] + [t["expr"] for t in panel["promql"]]
                names = {n for text in texts for n in bd.LABEL.findall(text)}
                new = {n for n in names if n in maximal.columns and maximal.columns[n] in proposed}
                declared = {k.replace(".", "_") for k in panel.get("requires", [])}
                for item in panel["columns"] + panel["promql"]:
                    declared |= {k.replace(".", "_") for k in item.get("requires", [])}
                self.assertLessEqual(new, declared, f"{dash['id']}/{panel['id']} uses an undeclared name")

    def test_conditional_panels_appear_when_the_conventions_have_the_attributes(self):
        ids = {p["id"] for d in self.dashboards for p in d["panels"]}
        self.assertTrue({"retries", "cache_hits", "rollbacks"}.isdisjoint(ids))
        richer = bd.load_conventions()
        for key in ("fespalier.data.attempt", "fespalier.data.source", "fespalier.action.rolled_back", "fespalier.action.invalid"):
            richer.attrs[key] = []
            richer.columns[key.replace(".", "_")] = key
        _, _, full = load(richer)
        ids = {p["id"] for d in full for p in d["panels"]}
        self.assertTrue({"retries", "cache_hits", "rollbacks"} <= ids)
        by_file = next(p for d in full for p in d["panels"] if p["id"] == "by_file")
        self.assertIn("AS retries", by_file["sql"])
        self.assertEqual(
            len([c for c in by_file["columns"] if c["axis"] == "y"]), len(by_file["promql"])
        )


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
                self.assertEqual("text", steps[0]["color"], "Grafana's default thresholds paint stats red")
            self.assertIsNone(overlaps(rects), path.name)
        self.assertEqual(len(uids), len(set(uids)))

    def test_both_backends_have_the_same_panels_in_order(self):
        for oo_path, gf_path in zip(oo_files(), gf_files()):
            oo = [p["title"] for p in read_json(oo_path)["tabs"][0]["panels"]]
            gf = [p["title"] for p in read_json(gf_path)["panels"]]
            self.assertEqual([t for t in oo if t != "Recent uncaught errors"], gf, oo_path.name)
        only_oo = [p["id"] for d in self.dashboards for p in d["panels"] if not p["grafana"]]
        self.assertEqual(["recent_uncaught"], only_oo)

    def test_tables_have_one_grafana_target_per_value_column(self):
        for dash in self.dashboards:
            for panel in dash["panels"]:
                if not panel["grafana"]:
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
                    self.assertNotRegex(text.replace("{{", "").replace("}}", ""), r"\{(?!\})[a-z_:|]+\}")
                    self.assertNotIn("{extra_columns}", text)
                self.assertIn("$service", panel["sql"])

    def test_the_seed_expects_a_count_for_every_count_stat(self):
        expected = seed_module.Seed(now=1_700_000_000).expected()
        stats = {
            f"{d['id']}/{p['id']}"
            for d in self.dashboards
            for p in d["panels"]
            if p["type"] == "stat" and not p.get("unit")
        }
        self.assertEqual(stats, set(expected))


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
        return [r for r in self.requests if r[0] in ("POST", "PUT")]


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
        self.assertEqual(6, len(titles))
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

    def test_a_fresh_install_waits_creates_streams_a_folder_and_six_dashboards(self):
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
        self.assertEqual(6, len(self.fake.dashboards))
        posts = [r for r in self.fake.requests if r[0] == "POST" and r[1] == "/api/default/dashboards"]
        self.assertEqual(6, len(posts))
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
        target = self.source / "dashboards/guards.json"
        dash = json.loads(target.read_text())
        dash["description"] = "changed by a new release"
        target.write_text(json.dumps(dash))
        guards = next(i for i, d in self.fake.dashboards.items() if d["title"] == dash["title"])
        listed = self.fake.dashboards[guards]["hash"]
        code, lines = self.run_importer()
        self.assertEqual(0, code)
        self.assertEqual(
            [f"fespalier: {t}: updated" if t == dash["title"] else f"fespalier: {t}: up to date" for t in self.titles],
            lines,
        )
        puts = [r for r in self.fake.requests if r[0] == "PUT" and "/dashboards/" in r[1]]
        self.assertEqual(1, len(puts))
        self.assertIn(f"hash={listed}", puts[0][2])
        self.assertEqual("changed by a new release", self.fake.dashboards[guards]["body"]["description"])

    def test_a_dashboard_edited_in_openobserve_is_left_alone(self):
        self.run_importer()
        target = self.source / "dashboards/guards.json"
        dash = json.loads(target.read_text())
        guards = next(i for i, d in self.fake.dashboards.items() if d["title"] == dash["title"])
        self.fake.dashboards[guards]["hash"] = "edited-in-the-ui"
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


if __name__ == "__main__":
    unittest.main(verbosity=1)
