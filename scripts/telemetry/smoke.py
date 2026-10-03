#!/usr/bin/env python3
"""Runs fespalier's telemetry stack in Docker and checks the dashboards against real data.

`just telemetry-smoke`, and the `telemetry-smoke` job of ci.yml. It needs Docker with Compose 2.20+.

1. Starts cli/templates/telemetry/compose.yaml (with Grafana) as the project
   `fespalier-telemetry-smoke`, pulling the pinned images (3 attempts).
2. Waits for the one-shot `dashboards` importer to exit 0.
3. Sends the seeded session (seed.py) to the collector.
4. Waits until the span metrics have all seeded spans.
5. Runs every OpenObserve panel's SQL and every Grafana target's PromQL: no errors.
6. Counts: the SQL value == the PromQL value == the seed's expected count; percentages: within 0.05
   of the seed's rate; quantiles: not null. The verdict table returns one row of eight verdicts.
7. Runs the importer again: `up to date` four times and nothing else.
8. Runs `report.py` (what `fsp telemetry --report` runs): it exits 0 and names the app.
9. Stops the stack and deletes its volumes.

`--no-start` skips steps 1 and 8 and uses a stack that is already running (`--project` names its
Compose project, for step 7). `--keep` leaves the stack up.
"""

import argparse
import base64
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_dashboards  # noqa: E402
import seed as seed_module  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
COMPOSE = ROOT / "cli/templates/telemetry/compose.yaml"
EMAIL, PASSWORD = "dev@fespalier.local", "Fespalier-local-1"
QUANTILES = {
    "health/screens_open",
    "health/content_loads",
    "health/actions_finish",
    "screens/screens_open",
    "screens/content_loads",
    "actions/actions_finish",
}
VERDICT = ("✓ ", "! ", "✗ ", "… ")
RATE_TOLERANCE = 0.05


class Smoke:
    def __init__(self, args):
        self.args = args
        self.service = seed_module.SERVICE
        self.failures = []
        token = base64.b64encode(f"{EMAIL}:{PASSWORD}".encode()).decode()
        self.o2_auth = f"Basic {token}"
        gf = base64.b64encode(f"admin:{PASSWORD}".encode()).decode()
        self.gf_auth = f"Basic {gf}"

    # -- helpers ------------------------------------------------------------------------------

    def compose(self, *words, check=True, capture=False, env=None):
        command = ["docker", "compose", "-f", str(COMPOSE), "-p", self.args.project, "--profile", "grafana", *words]
        result = subprocess.run(command, text=True, capture_output=capture, env=env)
        if check and result.returncode:
            raise SystemExit(f"{' '.join(command)} exited with {result.returncode}\n{result.stderr or ''}")
        return result

    def request(self, url, auth, body=None, method=None):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(
            url, data=data, method=method or ("POST" if body is not None else "GET"),
            headers={"Authorization": auth, "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.status, json.loads(response.read() or b"null")
        except urllib.error.HTTPError as error:
            text = error.read().decode()
            try:
                return error.code, json.loads(text)
            except ValueError:
                return error.code, text

    def fail(self, what):
        self.failures.append(what)
        print(f"FAIL {what}")

    def step(self, text):
        print(f"==> {text}", flush=True)

    # -- stack --------------------------------------------------------------------------------

    def start(self):
        self.step("pull and start the stack")
        for attempt in range(1, 4):
            if self.compose("pull", check=False).returncode == 0:
                break
            if attempt == 3:
                raise SystemExit("docker compose pull failed three times")
            time.sleep(5 * attempt)
        self.compose("up", "-d")
        self.step("wait for the dashboard importer")
        result = self.compose("wait", "dashboards", check=False)
        if result.returncode:
            self.compose("logs", "dashboards", check=False)
            raise SystemExit(f"the importer exited with {result.returncode}")

    def stop(self):
        if self.args.no_start or self.args.keep:
            return
        self.step("stop the stack and delete its volumes")
        self.compose("down", "-v", check=False)

    # -- checks -------------------------------------------------------------------------------

    def o2_query(self, expr, at=None):
        base = f"{self.args.openobserve}/api/default/prometheus/api/v1/query"
        query = urllib.parse.urlencode({"query": expr, "time": at or time.time()})
        return self.request(f"{base}?{query}", self.o2_auth)

    def wait_for_grafana(self):
        self.step("wait for Grafana")
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            try:
                status, body = self.request(f"{self.args.grafana_url}/api/health", self.gf_auth)
                if status == 200 and isinstance(body, dict) and body.get("database") == "ok":
                    return
            except OSError:
                pass
            time.sleep(2)
        self.fail("Grafana did not answer /api/health within 180 s")

    def check_provisioned(self):
        self.step("both UIs have the four dashboards")
        titles = sorted(f"fespalier · {d['title']}" for d in self.dashboards)
        base_o2 = self.args.openobserve
        status, folder = self.request(f"{base_o2}/api/v2/default/folders/dashboards/name/fespalier", self.o2_auth)
        folder_id = folder.get("folderId") if status == 200 else ""
        status, body = self.request(f"{base_o2}/api/default/dashboards?folder={folder_id}", self.o2_auth)
        found = sorted(item["title"] for item in body.get("dashboards", [])) if status == 200 else status
        if found != titles:
            self.fail(f"OpenObserve lists {found}, expected {titles}")
        base = self.args.grafana_url
        status, body = self.request(f"{base}/api/search?type=dash-db&tag=fespalier", self.gf_auth)
        found = sorted(item["title"] for item in body) if status == 200 else status
        if found != titles:
            self.fail(f"Grafana lists {found}, expected {titles}")
        status, body = self.request(f"{base}/api/datasources/uid/fespalier-openobserve/health", self.gf_auth)
        if status != 200 or body.get("status") != "OK":
            self.fail(f"the Grafana data source is not healthy: HTTP {status} {body}")

    def wait_for_metrics(self, spans):
        self.step(f"wait for {spans} span metrics")
        expr = f'sum(sum_over_time(fespalier_calls{{service_name="{self.service}"}}[1h]))'
        deadline = time.monotonic() + 120
        last = None
        while time.monotonic() < deadline:
            status, body = self.o2_query(expr)
            try:
                last = float(body["data"]["result"][0]["value"][1])
            except (TypeError, KeyError, IndexError, ValueError):
                last = None
            if last == spans:
                return
            time.sleep(3)
        self.fail(f"fespalier_calls reached {last}, not {spans}, in 120 s")

    def search(self, sql, stream_type):
        now = int(time.time() * 1e6)
        body = {"query": {"sql": sql, "start_time": now - 3600 * 10**6, "end_time": now + 60 * 10**6, "from": 0, "size": 50}}
        return self.request(
            f"{self.args.openobserve}/api/default/_search?type={stream_type}", self.o2_auth, body
        )

    def grafana(self, target):
        now = int(time.time() * 1000)
        query = {k: v for k, v in target.items() if k not in ("legendFormat",)}
        query.update({"intervalMs": 15000, "maxDataPoints": 500})
        body = {"queries": [query], "from": str(now - 3600 * 1000), "to": str(now)}
        return self.request(f"{self.args.grafana_url}/api/ds/query", self.gf_auth, body)

    def check_verdicts(self, rows):
        row = rows[0] if len(rows) == 1 else {}
        values = [v for k, v in row.items() if k != "app"]
        if len(rows) != 1 or len(values) != 8 or not all(str(v).startswith(VERDICT) for v in values):
            self.fail(f"health/verdicts: expected one row of eight verdicts, got {rows!r}")
        else:
            print(f"    health/verdicts: {values}")

    def check_panels(self, dashboards, expected, rates):
        self.step("run every panel's SQL (OpenObserve) and PromQL (Grafana)")
        sql_count = promql_count = 0
        for dash in dashboards:
            for panel in dash["panels"]:
                if panel["type"] == "text":
                    continue
                key = f"{dash['id']}/{panel['id']}"
                sql = panel["sql"].replace("$service", self.service)
                status, body = self.search(sql, panel["stream_type"])
                sql_count += 1
                sql_value = None
                if status != 200 or (isinstance(body, dict) and body.get("error")):
                    self.fail(f"{key}: SQL answered HTTP {status}: {str(body)[:300]}")
                else:
                    rows = body.get("hits", [])
                    if not rows:
                        self.fail(f"{key}: SQL returned no rows for the seed")
                    if panel["type"] == "stat" and rows:
                        sql_value = next(iter(rows[0].values()))
                    if key == "health/verdicts":
                        self.check_verdicts(rows)
                if not panel["grafana"]:
                    continue
                prom_value = None
                for index, target in enumerate(panel["promql"]):
                    expr = target["expr"].replace("$service", self.service)
                    stat = panel["type"] == "stat"
                    tabular = panel["type"] == "table" or (
                        panel["type"] == "bars" and not any(c.get("time") for c in panel["columns"])
                    )
                    query = {
                        "refId": "A",
                        "datasource": build_dashboards.DS,
                        "expr": expr,
                        "instant": stat or tabular,
                        "range": not (stat or tabular),
                    }
                    if tabular:
                        query["format"] = "table"
                    status, body = self.grafana(query)
                    # A range query ends on a step boundary, and OpenObserve stamps a delta
                    # sample at the next one: the newest samples show up a few seconds late.
                    for _ in range(12):
                        if status != 200 or self.has_data(body):
                            break
                        time.sleep(5)
                        status, body = self.grafana(query)
                    promql_count += 1
                    frame_error = body.get("results", {}).get("A", {}).get("error") if isinstance(body, dict) else None
                    if status != 200 or frame_error:
                        self.fail(f"{key}: PromQL target {index} answered HTTP {status}: {str(frame_error or body)[:300]}")
                    else:
                        if not self.has_data(body):
                            self.fail(f"{key}: PromQL target {index} returned no data for the seed")
                        if stat:
                            prom_value = self.stat_value(body)
                if panel["type"] != "stat":
                    continue
                print(f"    {key}: SQL {sql_value}, PromQL {prom_value}, seed {expected.get(key, rates.get(key, '-'))}")
                if key in expected:
                    if sql_value != expected[key]:
                        self.fail(f"{key}: SQL says {sql_value}, the seed says {expected[key]}")
                    if prom_value != expected[key]:
                        self.fail(f"{key}: PromQL says {prom_value}, the seed says {expected[key]}")
                elif key in rates:
                    for backend, value in (("SQL", sql_value), ("PromQL", prom_value)):
                        if value is None or abs(value - rates[key]) > RATE_TOLERANCE:
                            self.fail(f"{key}: {backend} says {value}, the seed says {rates[key]:.3f}")
                elif key in QUANTILES:
                    if sql_value is None or prom_value is None:
                        self.fail(f"{key}: a quantile is null (SQL {sql_value}, PromQL {prom_value})")
        print(f"    {sql_count} SQL queries and {promql_count} PromQL targets ran")

    @staticmethod
    def has_data(body):
        frames = body.get("results", {}).get("A", {}).get("frames", [])
        return any(v for frame in frames for v in frame["data"]["values"])

    @staticmethod
    def stat_value(body):
        frames = body.get("results", {}).get("A", {}).get("frames", [])
        if not frames:
            return None
        values = frames[0]["data"]["values"]
        if len(values) < 2 or not values[1]:
            return None
        value = values[1][0]
        if value is None or value != value:
            return None
        return int(value) if float(value).is_integer() else value

    def check_importer_again(self):
        self.step("run the importer again: it must change nothing")
        result = self.compose("run", "--rm", "-T", "dashboards", capture=True, check=False)
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        names = [d["title"] for d in json.loads(json.dumps(self.dashboards))]
        expected = sorted(f"fespalier: fespalier · {name}: up to date" for name in names)
        if result.returncode or sorted(lines) != expected or len(lines) != 4:
            self.fail(f"the second import printed {lines!r} (exit {result.returncode}), expected {expected!r}")

    def check_report(self):
        self.step("run the report (fsp telemetry --report): it must name the app")
        result = self.compose(
            "run", "--rm", "--no-deps", "-T", "dashboards", "python3", "/fespalier/report.py",
            capture=True, check=False,
        )
        print(result.stdout)
        header = f"fespalier · {self.service} · last hour"
        if result.returncode or header not in result.stdout:
            self.fail(f"the report exited {result.returncode} and printed {result.stdout!r} {result.stderr!r}")

    def run(self):
        files, self.dashboards = build_dashboards.build()
        generated = seed_module.Seed(self.service)
        try:
            if not self.args.no_start:
                self.start()
            self.step(f"send the seeded session ({generated.span_count()} spans)")
            for path, payload in (("/v1/traces", generated.traces_payload()), ("/v1/logs", generated.logs_payload())):
                status = seed_module.post(self.args.otlp, path, payload)
                if status != 200:
                    self.fail(f"{path} answered HTTP {status}")
            self.wait_for_metrics(generated.span_count())
            self.wait_for_grafana()
            self.check_provisioned()
            self.check_panels(self.dashboards, generated.expected(), generated.rates())
            self.check_importer_again()
            self.check_report()
        finally:
            if self.failures:
                self.compose("logs", "--no-color", "--tail", "40", check=False)
            self.stop()
        if self.failures:
            print(f"{len(self.failures)} failure(s)")
            return 1
        print("telemetry smoke: ok")
        return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--project", default="fespalier-telemetry-smoke")
    parser.add_argument("--no-start", action="store_true")
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--otlp", default="http://127.0.0.1:4318")
    parser.add_argument("--openobserve", default="http://127.0.0.1:5080")
    parser.add_argument("--grafana-url", default="http://127.0.0.1:3000")
    args = parser.parse_args(argv)
    return Smoke(args).run()


if __name__ == "__main__":
    sys.exit(main())
