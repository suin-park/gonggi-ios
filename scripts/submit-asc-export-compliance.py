#!/usr/bin/env python3
"""Submit ASC export-compliance exemption for a processed build.

Sets builds.attributes.usesNonExemptEncryption = false via
PATCH /v1/builds/{id}.

Requires ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_CONTENT.
Env: MARKETING_VERSION, BUILD_NUMBER, BUNDLE_ID.
"""

from __future__ import annotations

import json
import os
import sys
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


def api(method: str, path: str, tok: str, body: dict | None = None) -> dict:
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        f"https://api.appstoreconnect.apple.com{path}",
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {tok}",
            "Accept": "application/json",
            **({"Content-Type": "application/json"} if body is not None else {}),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        err = e.read().decode("utf-8", errors="replace")
        die(f"ASC {method} {path} → HTTP {e.code}: {err[:2000]}")


def find_build(tok: str, app_id: str, marketing: str, build: str) -> dict:
    builds = api(
        "GET",
        f"/v1/builds?filter[app]={app_id}"
        f"&filter[version]={build}"
        f"&filter[preReleaseVersion.version]={marketing}"
        f"&include=preReleaseVersion,buildBetaDetail"
        f"&limit=10&sort=-uploadedDate",
        tok,
    )
    rows = builds.get("data") or []
    if not rows:
        builds = api(
            "GET",
            f"/v1/builds?filter[app]={app_id}&filter[version]={build}"
            f"&include=preReleaseVersion,buildBetaDetail&limit=20&sort=-uploadedDate",
            tok,
        )
        rows = builds.get("data") or []
    included = {i["id"]: i for i in (builds.get("included") or [])}
    for b in rows:
        attrs = b.get("attributes") or {}
        ver = str(attrs.get("version") or "")
        marketing_match = True
        rel = ((b.get("relationships") or {}).get("preReleaseVersion") or {}).get("data")
        if rel and rel.get("id") in included:
            pr = included[rel["id"]].get("attributes") or {}
            marketing_match = str(pr.get("version") or "") == marketing
        if ver != build or not marketing_match:
            continue
        detail = {
            "id": b["id"],
            "version": ver,
            "processingState": attrs.get("processingState"),
            "usesNonExemptEncryption": attrs.get("usesNonExemptEncryption"),
            "uploadedDate": attrs.get("uploadedDate"),
        }
        bd_rel = ((b.get("relationships") or {}).get("buildBetaDetail") or {}).get("data")
        if bd_rel and bd_rel.get("id") in included:
            bda = included[bd_rel["id"]].get("attributes") or {}
            detail["externalBuildState"] = bda.get("externalBuildState")
            detail["internalBuildState"] = bda.get("internalBuildState")
            detail["buildBetaDetailId"] = bd_rel["id"]
        return detail
    die(f"Build {marketing} ({build}) not found")


def main() -> int:
    marketing = os.environ.get("MARKETING_VERSION", "2.0")
    build = os.environ.get("BUILD_NUMBER", "39")
    bundle = os.environ.get("BUNDLE_ID", "com.whik.gonggi")
    tok = token()

    apps = api("GET", "/v1/apps?filter[bundleId]=" + bundle, tok)
    data = apps.get("data") or []
    if not data:
        die(f"No app for bundle {bundle}")
    app_id = data[0]["id"]
    print(f"app_id={app_id}")

    before = find_build(tok, app_id, marketing, build)
    print("before=")
    print(json.dumps(before, indent=2))

    if before.get("processingState") not in ("VALID", "PROCESSED"):
        die(f"Refusing to patch non-VALID build: {before.get('processingState')}")

    internal_before = (before.get("internalBuildState") or "").upper()
    already_ok = (
        before.get("usesNonExemptEncryption") is False
        and "MISSING_EXPORT_COMPLIANCE" not in internal_before
    )
    if already_ok:
        print("already exempt / no MISSING_EXPORT_COMPLIANCE — skip PATCH")
        print(f"processingState={before.get('processingState')}")
        print(f"usesNonExemptEncryption={before.get('usesNonExemptEncryption')}")
        print(f"internalBuildState={before.get('internalBuildState')}")
        print("EXPORT_COMPLIANCE_OK=YES")
        return 0

    # Exempt encryption only (HTTPS / OS Keychain / hashing) → false.
    body = {
        "data": {
            "type": "builds",
            "id": before["id"],
            "attributes": {"usesNonExemptEncryption": False},
        }
    }
    print("PATCH usesNonExemptEncryption=false")
    api("PATCH", f"/v1/builds/{before['id']}", tok, body)

    after = find_build(tok, app_id, marketing, build)
    print("after=")
    print(json.dumps(after, indent=2))
    print(f"processingState={after.get('processingState')}")
    print(f"usesNonExemptEncryption={after.get('usesNonExemptEncryption')}")
    print(f"internalBuildState={after.get('internalBuildState')}")

    internal = (after.get("internalBuildState") or "").upper()
    if "MISSING_EXPORT_COMPLIANCE" in internal:
        die("MISSING_EXPORT_COMPLIANCE still present after patch")
    if after.get("usesNonExemptEncryption") is True:
        die("usesNonExemptEncryption still true")
    print("EXPORT_COMPLIANCE_OK=YES")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
