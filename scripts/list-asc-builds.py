#!/usr/bin/env python3
"""List builds of the app in App Store Connect (version, build number, processing state, upload date). No secrets printed."""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timedelta, timezone

import jwt


def token() -> str:
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    content = os.environ["ASC_KEY_CONTENT"].replace("\\n", "\n")
    now = datetime.now(timezone.utc)
    payload = {"iss": issuer, "iat": int(now.timestamp()), "exp": int((now + timedelta(minutes=15)).timestamp()), "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, content, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


def api(path: str, tok: str) -> dict:
    import urllib.request

    req = urllib.request.Request(f"https://api.appstoreconnect.apple.com{path}", headers={"Authorization": f"Bearer {tok}", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def main() -> int:
    bundle = os.environ.get("BUNDLE_ID", "com.whik.gonggi")
    tok = token()
    apps = api("/v1/apps?filter[bundleId]=" + bundle, tok).get("data") or []
    if not apps:
        print(json.dumps({"error": "APP_NOT_FOUND"}))
        return 1
    app_id = apps[0]["id"]
    builds = api(f"/v1/builds?filter[app]={app_id}&sort=-uploadedDate&limit=40&include=preReleaseVersion&fields[builds]=version,uploadedDate,processingState,expired,minOsVersion", tok)
    versions = {i["id"]: i["attributes"].get("version") for i in builds.get("included", []) if i.get("type") == "preReleaseVersions"}
    rows = []
    for b in builds.get("data", []):
        a = b["attributes"]
        pre = (b.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}).get("id")
        rows.append({"marketing": versions.get(pre), "build": a.get("version"), "state": a.get("processingState"), "uploaded": a.get("uploadedDate"), "expired": a.get("expired")})
    print(json.dumps({"bundle": bundle, "count": len(rows), "builds": rows}, ensure_ascii=False, indent=1))
    nums = [int(r["build"]) for r in rows if str(r["build"]).isdigit()]
    print("HIGHEST_BUILD_NUMBER", max(nums) if nums else None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
