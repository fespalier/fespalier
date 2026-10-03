#!/usr/bin/env python3
"""fespalier's report in plain words (`fsp telemetry --report`, since 0.8.1).

Runs in the `dashboards` container of the stack (Python's standard library only), against the
running OpenObserve. For each app that sent fespalier spans in the last hour it prints how the app
is doing: one line per question on the App health dashboard, the slowest screen, and what fails
most. It runs the very SQL of App health's panels, read from dashboards/health.json, so the report
and the dashboard cannot disagree.

Settings (environment): FSP_O2_URL, FSP_O2_EMAIL, FSP_O2_PASSWORD, FSP_O2_PORT (the port shown in
the last line), FSP_SOURCE_DIR (the folder with dashboards/ and import.py, this script's own).
"""

import importlib.util
import json
import os
import re
import sys
import time

HOUR = 3600 * 10**6
WORDS = {"✓": "good", "!": "needs attention", "✗": "bad", "…": "too few to judge"}
GRADES = ("good", "attention", "bad")
MARKS = {"good": "✓ good", "attention": "! needs attention", "bad": "✗ bad"}
NO_SPANS = (
    "no fespalier spans in the last hour: is the app running, with telemetry: true and "
    'FespalierOtel installed? (README, "Telemetry")'
)


def load_importer(source):
    """import.py's Client, wait_ready and fail (`import` is a keyword, so by path)."""
    spec = importlib.util.spec_from_file_location("fespalier_import", os.path.join(source, "import.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def panel_of(dashboard, panel_id):
    for panel in dashboard["tabs"][0]["panels"]:
        if panel["id"] == f"panel_{panel_id}":
            return panel
    raise SystemExit(f"fespalier: dashboards/health.json has no panel {panel_id}; run fsp telemetry again")


class Report:
    def __init__(self, client, fail, dashboard, port):
        self.client = client
        self.fail = fail
        self.dashboard = dashboard
        self.port = port

    def search(self, sql, stream_type):
        now = int(time.time() * 1e6)
        body = {
            "query": {"sql": sql, "start_time": now - HOUR, "end_time": now + 60 * 10**6, "from": 0, "size": 50}
        }
        status, reply = self.client.call("POST", f"/api/default/_search?type={stream_type}", body)
        if status != 200 or (isinstance(reply, dict) and reply.get("error")):
            self.fail(f"the report's query failed: HTTP {status}: {str(reply)[:300]}")
        return reply.get("hits", [])

    def run_panel(self, panel_id, app):
        panel = panel_of(self.dashboard, panel_id)
        query = panel["queries"][0]
        sql = query["query"].replace("$service", app.replace("'", "''"))
        return panel, self.search(sql, query["fields"]["stream_type"])

    def apps(self):
        sql = 'SELECT DISTINCT service_name AS app FROM "default" WHERE fespalier_operation IS NOT NULL'
        return sorted(row["app"] for row in self.search(sql, "traces") if row.get("app"))

    # -- lines ----------------------------------------------------------------------------

    @staticmethod
    def duration(ms):
        return f"{ms / 1000:.1f} s" if ms >= 1000 else f"{round(ms)} ms"

    @staticmethod
    def parse_verdict(text):
        """('✓', '240 ms') from '✓ Good · 240 ms'; ('…', '12 samples') from '… Too few to judge (12)'."""
        mark = text[0]
        if mark == "…":
            found = re.search(r"\((\d+)\)", text)
            count = int(found.group(1)) if found else 0
            return mark, f"{count} sample{'' if count == 1 else 's'}"
        return mark, text.split(" · ", 1)[1] if " · " in text else ""

    def grade_of_count(self, panel, count):
        """The grade of a count, from the panel's own mappings: the last one at or below it."""
        steps = [m for m in panel["config"]["mappings"] if m["type"] == "gte"]
        grade_names = GRADES if len(steps) == 3 else ("good", "bad")
        grade = grade_names[0]
        for name, step in zip(grade_names, steps):
            if count >= float(step["value"]):
                grade = name
        return grade

    def lines_for(self, app):
        verdicts, rows = self.run_panel("verdicts", app)
        row = rows[0] if rows else {}
        entries = []
        for item in verdicts["queries"][0]["fields"]["y"]:
            text = row.get(item["alias"])
            if not text:
                continue
            mark, shown = self.parse_verdict(text)
            entries.append((f"{mark} {WORDS[mark]}", item["label"], shown))
        for panel_id in ("uncaught", "crashes"):
            panel, rows = self.run_panel(panel_id, app)
            count = int(next(iter(rows[0].values())) or 0) if rows else 0
            grade = self.grade_of_count(panel, count)
            entries.append((MARKS[grade], panel["title"], str(count) if count else "none"))
        width = max(len(question) for _, question, _ in entries) + 2
        lines = [f"fespalier · {app} · last hour"]
        for word, question, shown in entries:
            lines.append(f"  {word.ljust(21)}{question.ljust(width)}{shown}")
        lines.append(self.slowest(app))
        lines.append(self.fails_most(app))
        lines.append(
            f"  Details: http://localhost:{self.port}, Dashboards, folder fespalier, "
            f"{self.dashboard['title']}"
        )
        return [line for line in lines if line]

    def slowest(self, app):
        _, rows = self.run_panel("slowest_screens", app)
        if not rows or rows[0].get("open_p95") is None:
            return ""
        top = rows[0]
        text = f"  Slowest screen: {top['route']}, {self.duration(top['open_p95'])} to open"
        if top.get("content_p95") is not None:
            text += f" and {self.duration(top['content_p95'])} for its content"
        views = int(top.get("views") or 0)
        return f"{text} (slowest 5 %, {views} view{'' if views == 1 else 's'})"

    def fails_most(self, app):
        panel, rows = self.run_panel("top_failures", app)
        if not rows:
            return "  Nothing failed."
        top = rows[0]
        names = {m["value"]: m["text"] for m in panel["config"].get("mappings", []) if m["type"] == "value"}
        kind = names.get(top.get("operation"), top.get("operation") or "Something")
        where = " ".join(part for part in (top.get("file"), f"on {top['route']}" if top.get("route") else "") if part)
        return f"  Fails most: {kind}{' ' + where if where else ''}, {int(top['n'])} × {top.get('type') or 'error'}"


def main():
    source = os.environ.get("FSP_SOURCE_DIR") or os.path.dirname(os.path.abspath(__file__))
    importer = load_importer(source)
    client = importer.Client(
        os.environ.get("FSP_O2_URL", "http://openobserve:5080"),
        os.environ.get("FSP_O2_EMAIL", "dev@fespalier.local"),
        os.environ.get("FSP_O2_PASSWORD", "Fespalier-local-1"),
    )
    importer.wait_ready(client, 5)
    with open(os.path.join(source, "dashboards", "health.json"), encoding="utf-8") as handle:
        dashboard = json.load(handle)
    report = Report(client, importer.fail, dashboard, os.environ.get("FSP_O2_PORT", "5080"))
    try:
        apps = report.apps()
        if not apps:
            print(NO_SPANS, flush=True)
            return
        blocks = ["\n".join(report.lines_for(app)) for app in apps]
    except OSError as error:
        importer.fail(f"OpenObserve stopped answering at {client.url}: {error}")
    print("\n\n".join(blocks), flush=True)


if __name__ == "__main__":
    main()
