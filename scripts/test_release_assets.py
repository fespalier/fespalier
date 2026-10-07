#!/usr/bin/env python3
"""Runs scripts/release-assets.sh end to end against a fake GitHub API.

    python3 scripts/test_release_assets.py

The fake models only what the script relies on, as documented for the REST API: drafts are listed
(newest first, `per_page`/`page`) only to a token with write access, a draft keeps the `tag_name`
it was given without any git tag, asset names are unique per release (422 otherwise), asset
downloads redirect to a blob URL, and publishing is a PATCH of `draft`. It proves the script's
logic (replace, fetch, wait, attach, publish, drop), not GitHub's behaviour: that only a real
release can show (see docs/releasing.md). Needs bash, curl and jq; skipped without them.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SCRIPT = Path(__file__).resolve().parent / "release-assets.sh"
REPO = "o/r"
TOOLS = all(shutil.which(t) for t in ("bash", "curl", "jq"))


class Fake:
    def __init__(self):
        self.releases = []  # newest first
        self.blobs = {}
        self.next_id = 100
        self.requests = []

    def new_id(self):
        self.next_id += 1
        return self.next_id

    def release(self, rid):
        return next((r for r in self.releases if r["id"] == rid), None)

    def view(self, r):
        return {k: v for k, v in r.items() if k != "_token"} | {"html_url": f"https://example/releases/{r['id']}"}


def handler_for(fake: Fake):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, body=None, headers=None):
            raw = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
            self.send_response(code)
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def writer(self):
            return self.headers.get("Authorization") == "Bearer writer"

        def body(self):
            n = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(n)

        def route(self, method):
            url = urlparse(self.path)
            q = parse_qs(url.query)
            path = url.path
            fake.requests.append((method, path))
            if self.headers.get("Authorization") not in ("Bearer writer", "Bearer reader"):
                return self.send(401, {"message": "Bad credentials"})
            base = f"/repos/{REPO}/releases"
            if method == "GET" and path == base:
                visible = [r for r in fake.releases if self.writer() or not r["draft"]]
                per, page = int(q["per_page"][0]), int(q["page"][0])
                return self.send(200, [fake.view(r) for r in visible[(page - 1) * per : page * per]])
            if method == "POST" and path == base:
                if not self.writer():
                    return self.send(404, {"message": "Not Found"})
                data = json.loads(self.body())
                r = {"id": fake.new_id(), "tag_name": data["tag_name"], "name": data.get("name"), "draft": bool(data.get("draft")), "assets": []}
                fake.releases.insert(0, r)
                return self.send(201, fake.view(r))
            m = re.fullmatch(rf"{base}/(\d+)", path)
            if m:
                r = fake.release(int(m[1]))
                if r is None or (r["draft"] and not self.writer()):
                    return self.send(404, {"message": "Not Found"})
                if method == "GET":
                    return self.send(200, fake.view(r))
                if method == "PATCH":
                    data = json.loads(self.body())
                    r["draft"] = data.get("draft", r["draft"])
                    r["make_latest"] = data.get("make_latest")
                    return self.send(200, fake.view(r))
                if method == "DELETE":
                    fake.releases.remove(r)
                    return self.send(204)
            m = re.fullmatch(rf"/uploads/repos/{REPO}/releases/(\d+)/assets", path)
            if method == "POST" and m:
                r = fake.release(int(m[1]))
                name = q["name"][0]
                if any(a["name"] == name for a in r["assets"]):
                    return self.send(422, {"message": "Validation Failed", "errors": [{"code": "already_exists", "field": "name"}]})
                data = self.body()
                a = {"id": fake.new_id(), "name": name, "size": len(data)}
                fake.blobs[a["id"]] = data
                r["assets"].append(a)
                return self.send(201, a)
            m = re.fullmatch(rf"{base}/assets/(\d+)", path)
            if m:
                aid = int(m[1])
                if method == "GET":
                    # Like GitHub: only a request that accepts octet-stream, and not the JSON
                    # media type as well, gets the file; anything else gets the metadata.
                    accepts = ", ".join(self.headers.get_all("Accept") or [])
                    if "application/octet-stream" in accepts and "json" not in accepts:
                        return self.send(302, headers={"Location": f"/blob/{aid}"})
                    asset = next(a for r in fake.releases for a in r["assets"] if a["id"] == aid)
                    return self.send(200, asset)
                if method == "DELETE":
                    for r in fake.releases:
                        r["assets"] = [a for a in r["assets"] if a["id"] != aid]
                    return self.send(204)
            m = re.fullmatch(r"/blob/(\d+)", path)
            if method == "GET" and m:
                return self.send(200, fake.blobs[int(m[1])])
            return self.send(404, {"message": f"no route {method} {path}"})

        def do_GET(self):
            self.route("GET")

        def do_POST(self):
            self.route("POST")

        def do_PATCH(self):
            self.route("PATCH")

        def do_DELETE(self):
            self.route("DELETE")

    return H


@unittest.skipUnless(TOOLS, "needs bash, curl and jq")
class ReleaseAssets(unittest.TestCase):
    def setUp(self):
        self.fake = Fake()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(self.fake))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        host = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.env = {
            **os.environ,
            "GH_TOKEN": "writer",
            "GITHUB_REPOSITORY": REPO,
            "GITHUB_API_URL": host,
            "GITHUB_UPLOADS_URL": f"{host}/uploads",
        }

    def run_script(self, *args, token="writer", check=True):
        env = {**self.env, "GH_TOKEN": token}
        p = subprocess.run(["bash", str(SCRIPT), *args], env=env, capture_output=True, text=True, timeout=60)
        if check and p.returncode != 0:
            self.fail(f"{args} exited {p.returncode}\n{p.stdout}\n{p.stderr}")
        return p

    def dist(self, payload=b"a"):
        d = self.tmp / f"dist-{len(list(self.tmp.iterdir()))}"
        d.mkdir()
        for t in ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu", "x86_64-apple-darwin", "aarch64-apple-darwin"):
            (d / f"fsp-{t}.tar.gz").write_bytes(payload + t.encode())
        (d / "fsp-x86_64-pc-windows-msvc.zip").write_bytes(payload + b"win")
        (d / "build-info.json").write_text('{"version": "1.2.3"}')
        return d

    def staging(self):
        return [r for r in self.fake.releases if r["tag_name"] == "fsp-staging"]

    def test_stage_then_fetch_returns_the_same_bytes(self):
        src = self.dist()
        self.run_script("stage", str(src))
        self.assertEqual(len(self.staging()), 1)
        self.assertTrue(self.staging()[0]["draft"])
        out = self.tmp / "out"
        self.run_script("fetch", str(out))
        self.assertEqual(sorted(p.name for p in out.iterdir()), sorted(p.name for p in src.iterdir()))
        for p in src.iterdir():
            self.assertEqual((out / p.name).read_bytes(), p.read_bytes(), p.name)

    def test_a_new_stage_replaces_the_old_one(self):
        self.run_script("stage", str(self.dist(b"old")))
        self.run_script("stage", str(self.dist(b"new")))
        self.assertEqual(len(self.staging()), 1, "exactly one staging draft")
        out = self.tmp / "out"
        self.run_script("fetch", str(out))
        self.assertTrue((out / "fsp-x86_64-apple-darwin.tar.gz").read_bytes().startswith(b"new"))

    def test_stage_refuses_an_incomplete_dist(self):
        d = self.dist()
        (d / "fsp-x86_64-apple-darwin.tar.gz").unlink()
        self.assertNotEqual(self.run_script("stage", str(d), check=False).returncode, 0)
        self.assertEqual(self.staging(), [])

    def test_fetch_fails_loudly_without_a_staging_draft(self):
        p = self.run_script("fetch", str(self.tmp / "out"), check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("no staging draft", p.stderr)

    def test_a_token_without_write_access_cannot_see_the_draft(self):
        self.run_script("stage", str(self.dist()))
        p = self.run_script("fetch", str(self.tmp / "out"), token="reader", check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("no staging draft", p.stderr)

    def test_the_staging_draft_is_found_past_the_first_page(self):
        self.run_script("stage", str(self.dist()))
        for i in range(120):  # newer releases push it onto page 2
            self.fake.releases.insert(0, {"id": 1000 + i, "tag_name": f"v0.0.{i}", "draft": False, "assets": []})
        self.run_script("fetch", str(self.tmp / "out"))

    def test_attach_publish_and_drop_end_with_one_published_release(self):
        # release-please made the draft release v1.2.3 (and its tag); release.yml attaches to it
        self.fake.releases.insert(0, {"id": 7, "tag_name": "v1.2.3", "name": "v1.2.3", "draft": True, "assets": []})
        self.run_script("stage", str(self.dist()))
        out = self.tmp / "out"
        self.run_script("fetch", str(out))
        files = sorted(str(p) for p in out.iterdir() if p.name != "build-info.json")
        self.run_script("attach", "v1.2.3", *files)
        self.run_script("publish", "v1.2.3")
        self.run_script("drop")
        tagged = [r for r in self.fake.releases if r["tag_name"] == "v1.2.3"]
        self.assertEqual(len(tagged), 1, "no second release is created for the tag")
        self.assertFalse(tagged[0]["draft"])
        self.assertEqual(tagged[0]["make_latest"], "true")
        self.assertEqual(sorted(a["name"] for a in tagged[0]["assets"]), sorted(Path(f).name for f in files))
        self.assertEqual(self.staging(), [])

    def test_attach_replaces_an_asset_of_the_same_name(self):
        self.fake.releases.insert(0, {"id": 7, "tag_name": "v1.2.3", "draft": True, "assets": []})
        f = self.tmp / "fsp.rb"
        f.write_text("one")
        self.run_script("attach", "v1.2.3", str(f))
        f.write_text("two!")
        self.run_script("attach", "v1.2.3", str(f))
        (asset,) = self.fake.release(7)["assets"]
        self.assertEqual(self.fake.blobs[asset["id"]], b"two!")

    def test_ensure_waits_for_release_please_and_then_finds_it(self):
        threading.Timer(2.0, lambda: self.fake.releases.insert(0, {"id": 7, "tag_name": "v1.2.3", "draft": True, "assets": []})).start()
        p = self.run_script("ensure", "v1.2.3", "60")
        self.assertEqual(p.stdout.strip(), "7")
        self.assertEqual(len(self.fake.releases), 1)

    def test_ensure_creates_a_draft_only_when_the_release_never_appears(self):
        p = self.run_script("ensure", "v9.9.9", "0")
        (r,) = self.fake.releases
        self.assertEqual((r["tag_name"], r["draft"]), ("v9.9.9", True))
        self.assertEqual(p.stdout.strip(), str(r["id"]))
        self.assertIn("did not create a release", p.stderr)

    def test_publish_does_not_invent_a_release(self):
        p = self.run_script("publish", "v9.9.9", check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.fake.releases, [])


if __name__ == "__main__":
    unittest.main()
