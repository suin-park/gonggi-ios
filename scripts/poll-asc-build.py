#!/usr/bin/env python3
"""Poll App Store Connect until marketing+build is processed / TF visible."""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

import jwt


def die(msg: str) -> None:
    print(f"::error::{msg}")
    sys.exit(1)


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
        die(f"No app for bundle {bundle}")
    app_id = data[0]["id"]
    print(f"app_id={app_id}")

    deadline = time.time() + 40 * 60
    found = None
    while time.time() < deadline:
        tok = token()
        builds = api(
            f"/v1/builds?filter[app]={app_id}"
            f"&filter[version]={build}"
            f"&filter[preReleaseVersion.version]={marketing}"
            f"&include=preReleaseVersion,buildBetaDetail"
            f"&limit=10"
            f"&sort=-uploadedDate",
            tok,
        )
        rows = builds.get("data") or []
        # Fallback without preReleaseVersion filter (some ASC quirks)
        if not rows:
            builds = api(
                f"/v1/builds?filter[app]={app_id}&filter[version]={build}"
                f"&include=preReleaseVersion,buildBetaDetail&limit=20&sort=-uploadedDate",
                tok,
            )
            rows = [
                b
                for b in (builds.get("data") or [])
                if True
            ]
        for b in rows:
            attrs = b.get("attributes") or {}
            ver = str(attrs.get("version") or "")
            processing = attrs.get("processingState")
            # Resolve marketing from included preReleaseVersion when present
            marketing_match = True
            included = {i["id"]: i for i in (builds.get("included") or [])}
            rel = ((b.get("relationships") or {}).get("preReleaseVersion") or {}).get("data")
            if rel and rel.get("id") in included:
                pr = included[rel["id"]].get("attributes") or {}
                marketing_match = str(pr.get("version") or "") == marketing
            if ver == build and marketing_match:
                found = {
                    "id": b.get("id"),
                    "version": ver,
                    "processingState": processing,
                    "uploadedDate": attrs.get("uploadedDate"),
                    "expired": attrs.get("expired"),
                }
                # beta detail
                bd_rel = ((b.get("relationships") or {}).get("buildBetaDetail") or {}).get("data")
                if bd_rel and bd_rel.get("id") in included:
                    bda = included[bd_rel["id"]].get("attributes") or {}
                    found["externalBuildState"] = bda.get("externalBuildState")
                    found["internalBuildState"] = bda.get("internalBuildState")
                break
        if found:
            print(json.dumps(found, indent=2))
            state = (found.get("processingState") or "").upper()
            print(f"processingState={state}")
            if state in ("VALID", "PROCESSED"):
                internal = found.get("internalBuildState")
                print(f"internalBuildState={internal}")
                print("BUILD_VISIBLE=YES")
                return 0
            if state in ("FAILED", "INVALID"):
                die(f"Build processing failed: {state}")
        else:
            print("build not listed yet; sleeping 30s")
        time.sleep(30)

    die(f"Timed out waiting for {marketing} ({build})")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
