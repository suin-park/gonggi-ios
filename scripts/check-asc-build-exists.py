#!/usr/bin/env python3
"""One-shot: exit 0 if marketing+build absent; exit 2 if present (any processing state)."""

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
    payload = {
        "iss": issuer,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=15)).timestamp()),
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(payload, content, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


def api(path: str, tok: str) -> dict:
    import urllib.request

    req = urllib.request.Request(
        f"https://api.appstoreconnect.apple.com{path}",
        headers={"Authorization": f"Bearer {tok}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def main() -> int:
    marketing = os.environ["MARKETING_VERSION"]
    build = os.environ["BUILD_NUMBER"]
    bundle = os.environ["BUNDLE_ID"]
    tok = token()
    apps = api("/v1/apps?filter[bundleId]=" + bundle, tok)
    data = apps.get("data") or []
    if not data:
        print(json.dumps({"error": "APP_NOT_FOUND"}))
        return 1
    app_id = data[0]["id"]
    builds = api(
        f"/v1/builds?filter[app]={app_id}&filter[version]={build}"
        f"&include=preReleaseVersion&limit=20&sort=-uploadedDate",
        tok,
    )
    included = {i["id"]: i for i in (builds.get("included") or [])}
    hits = []
    for b in builds.get("data") or []:
        attrs = b.get("attributes") or {}
        if str(attrs.get("version") or "") != build:
            continue
        marketing_match = True
        rel = ((b.get("relationships") or {}).get("preReleaseVersion") or {}).get("data")
        if rel and rel.get("id") in included:
            pr = included[rel["id"]].get("attributes") or {}
            marketing_match = str(pr.get("version") or "") == marketing
        if marketing_match:
            hits.append(
                {
                    "id": b.get("id"),
                    "version": attrs.get("version"),
                    "processingState": attrs.get("processingState"),
                }
            )
    out = {"marketing": marketing, "build": build, "exists": len(hits) > 0, "hits": hits}
    print(json.dumps(out, indent=2))
    if hits:
        print("BUILD_EXISTS=YES")
        return 2
    print("BUILD_EXISTS=NO")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
