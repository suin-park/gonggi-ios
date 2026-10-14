#!/usr/bin/env python3
"""Show (and with SET_NAME=1 change) the App Store Connect display name of the app. Never prints secrets."""
from __future__ import annotations
import json, os, sys, urllib.request, urllib.error
sys.path.insert(0, os.path.dirname(__file__))
import importlib.util
spec = importlib.util.spec_from_file_location("lab", os.path.join(os.path.dirname(__file__), "list-asc-builds.py"))
lab = importlib.util.module_from_spec(spec); spec.loader.exec_module(lab)

WANT = "커모"

def call(method, path, tok, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {tok}", "Accept": "application/json", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

def main():
    tok = lab.token()
    _, apps = call("GET", "/v1/apps?filter[bundleId]=" + os.environ.get("BUNDLE_ID", "com.whik.gonggi"), tok)
    app = apps["data"][0]
    print("APP", app["id"], "name:", app["attributes"].get("name"), "primaryLocale:", app["attributes"].get("primaryLocale"))
    _, infos = call("GET", f"/v1/apps/{app['id']}/appInfos", tok)
    for info in infos.get("data", []):
        print("APPINFO", info["id"], info["attributes"].get("appStoreState"), info["attributes"].get("state"))
        _, locs = call("GET", f"/v1/appInfos/{info['id']}/appInfoLocalizations", tok)
        for l in locs.get("data", []):
            a = l["attributes"]
            print("  LOC", l["id"], a.get("locale"), "name:", a.get("name"), "subtitle:", a.get("subtitle"))
            if os.environ.get("SET_NAME") == "1" and a.get("name") != WANT:
                st, res = call("PATCH", f"/v1/appInfoLocalizations/{l['id']}", tok,
                               {"data": {"type": "appInfoLocalizations", "id": l["id"], "attributes": {"name": WANT}}})
                print("  PATCH", st, json.dumps(res.get("errors", "ok"), ensure_ascii=False)[:600])
    return 0

sys.exit(main())
