#!/usr/bin/env python3
"""fespalier's dashboard importer for OpenObserve (since 0.8.0).

Runs once per `fsp telemetry`, in the `dashboards` container of the stack (Python's standard
library only). OpenObserve does not read dashboard files, so this script:

1. waits for OpenObserve's API,
2. creates the `traces` and `logs` streams with the columns the panels name (a panel on a column
   that was never ingested fails with `unknown field`),
3. creates the `fespalier` dashboard folder, and
4. creates or updates each dashboards/*.json in it. A dashboard someone edited in OpenObserve is
   left alone.

Settings (environment): FSP_O2_URL, FSP_O2_EMAIL, FSP_O2_PASSWORD, FSP_O2_WAIT (seconds to wait,
180), FSP_STATE_DIR (where imported.json lives, /state) and FSP_SOURCE_DIR (the folder with
dashboards/ and fields.json, this script's own).
"""

import base64
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

FOLDER = "fespalier"


def say(text):
    print(f"fespalier: {text}", flush=True)


def fail(text):
    say(text)
    sys.exit(1)


class Client:
    def __init__(self, url, email, password):
        self.url = url.rstrip("/")
        token = base64.b64encode(f"{email}:{password}".encode()).decode()
        self.headers = {"Authorization": f"Basic {token}", "Content-Type": "application/json"}

    def call(self, method, path, body=None):
        """Returns (status, parsed JSON or text). Raises OSError when nothing answers."""
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(
            self.url + path, data=data, method=method, headers=self.headers
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                status, text = response.status, response.read().decode()
        except urllib.error.HTTPError as error:
            status, text = error.code, error.read().decode()
        try:
            return status, json.loads(text)
        except ValueError:
            return status, text


def wait_ready(client, seconds):
    """`/healthz` answers before the root user exists, so poll an authenticated endpoint."""
    deadline = time.monotonic() + seconds
    last = "no answer yet"
    while True:
        try:
            status, _ = client.call("GET", "/api/default/dashboards")
            if status == 200:
                return
            last = f"HTTP {status}"
        except OSError as error:
            last = str(error)
        if time.monotonic() >= deadline:
            fail(f"OpenObserve did not answer at {client.url} within {seconds}s ({last}).")
        time.sleep(1)


def ensure_stream(client, stream_type, wanted):
    path = f"/api/default/streams/default/schema?type={stream_type}"
    status, body = client.call("GET", path)
    if status == 404:
        fields = [{"name": name, "type": "Utf8"} for name in wanted]
        status, body = client.call(
            "POST",
            f"/api/default/streams/default?type={stream_type}",
            {"fields": fields, "settings": {}},
        )
        if status != 200:
            fail(f"the {stream_type} stream: OpenObserve answered HTTP {status}: {body}")
        say(f"created the {stream_type} stream with {len(fields)} fields")
        return
    if status != 200:
        fail(f"the {stream_type} stream: OpenObserve answered HTTP {status}: {body}")
    have = {field["name"] for field in body.get("schema", [])}
    missing = [{"name": name, "type": "Utf8"} for name in wanted if name not in have]
    if not missing:
        return
    status, body = client.call(
        "PUT",
        f"/api/default/streams/default/settings?type={stream_type}",
        {"fields": {"add": missing}},
    )
    if status != 200:
        fail(f"the {stream_type} stream: OpenObserve answered HTTP {status}: {body}")
    say(f"added {len(missing)} fields to the {stream_type} stream")


def ensure_folder(client):
    status, body = client.call("GET", f"/api/v2/default/folders/dashboards/name/{FOLDER}")
    if status == 404:
        status, body = client.call(
            "POST",
            "/api/v2/default/folders/dashboards",
            {"name": FOLDER, "description": "Dashboards written by fsp telemetry."},
        )
    if status != 200:
        fail(f"could not create the fespalier folder: HTTP {status} {body}")
    return body["folderId"]


def load_state(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def save_state(path, state):
    """Atomically: a temp file in the same folder, then a rename."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)


def import_dashboards(client, folder_id, source, state_path):
    state = load_state(state_path)
    status, body = client.call("GET", f"/api/default/dashboards?folder={folder_id}")
    if status != 200:
        fail(f"could not list the fespalier dashboards: HTTP {status} {body}")
    remote = {item["title"]: item for item in body.get("dashboards", [])}
    folder_dir = os.path.join(source, "dashboards")
    for name in sorted(os.listdir(folder_dir)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(folder_dir, name), "rb") as handle:
            raw = handle.read()
        dashboard = json.loads(raw)
        title = dashboard["title"]
        digest = hashlib.sha256(raw).hexdigest()
        known = state.get(title)
        current = remote.get(title)
        if current is None:
            status, reply = client.call(
                "POST", f"/api/default/dashboards?folder={folder_id}", dashboard
            )
            outcome = "created"
        elif known and known["source"] == digest:
            say(f"{title}: up to date")
            continue
        elif known and known["hash"] != current["hash"]:
            say(
                f"{title}: changed in OpenObserve since fsp telemetry wrote it, left alone; "
                "delete it to get the new version"
            )
            continue
        else:
            query = urllib.parse.urlencode({"folder": folder_id, "hash": current["hash"]})
            status, reply = client.call(
                "PUT", f"/api/default/dashboards/{current['dashboard_id']}?{query}", dashboard
            )
            outcome = "updated"
        if status != 200:
            fail(f"{title}: OpenObserve answered HTTP {status}: {reply}")
        state[title] = {"source": digest, "hash": reply["hash"]}
        save_state(state_path, state)
        say(f"{title}: {outcome}")


def main():
    source = os.environ.get("FSP_SOURCE_DIR") or os.path.dirname(os.path.abspath(__file__))
    client = Client(
        os.environ.get("FSP_O2_URL", "http://openobserve:5080"),
        os.environ.get("FSP_O2_EMAIL", "dev@fespalier.local"),
        os.environ.get("FSP_O2_PASSWORD", "Fespalier-local-1"),
    )
    state_dir = os.environ.get("FSP_STATE_DIR", "/state")
    wait_ready(client, int(os.environ.get("FSP_O2_WAIT", "180")))
    with open(os.path.join(source, "fields.json"), encoding="utf-8") as handle:
        fields = json.load(handle)
    try:
        for stream_type in ("traces", "logs"):
            ensure_stream(client, stream_type, fields[stream_type])
        folder_id = ensure_folder(client)
        import_dashboards(client, folder_id, source, os.path.join(state_dir, "imported.json"))
    except OSError as error:
        fail(f"OpenObserve stopped answering at {client.url}: {error}")


if __name__ == "__main__":
    main()
