#!/usr/bin/env python3
"""
Ensure App Store provisioning profile for com.whik.gonggi includes Sign in with Apple.
Uses App Store Connect API (ASC_KEY_*). Prints paths only — never prints key material.
"""
from __future__ import annotations

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.whik.gonggi")
TEAM_ID = os.environ["APPLE_TEAM_ID"]
KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER_ID = os.environ["ASC_ISSUER_ID"]
KEY_PATH = Path(os.environ.get("ASC_KEY_PATH", "")).expanduser()
OUT_PROFILE = Path(os.environ["OUT_PROFILE_PATH"])
OUT_META = Path(os.environ.get("OUT_PROFILE_META", str(OUT_PROFILE) + ".json"))


def die(msg: str, code: int = 1) -> None:
    print(f"::error::{msg}", file=sys.stderr)
    raise SystemExit(code)


def load_private_key_pem() -> str:
    if KEY_PATH.is_file():
        return KEY_PATH.read_text(encoding="utf-8")
    content = os.environ.get("ASC_KEY_CONTENT", "")
    if not content.strip():
        die("ASC_KEY_PATH or ASC_KEY_CONTENT required")
    return content if "BEGIN" in content else content.replace("\\n", "\n")


def make_token() -> str:
    try:
        import jwt  # PyJWT
    except ImportError:
        die("PyJWT required (pip install PyJWT cryptography)")

    pem = load_private_key_pem()
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 20 * 60, "aud": "appstoreconnect-v1"},
        pem,
        algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"},
    )


def api(method: str, path: str, token: str, body: dict | None = None) -> dict:
    url = path if path.startswith("http") else f"https://api.appstoreconnect.apple.com{path}"
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        err = e.read().decode("utf-8", errors="replace")
        die(f"ASC API {method} {path} -> HTTP {e.code}: {err[:800]}")


def find_bundle(token: str) -> dict:
    q = urllib.parse.urlencode({"filter[identifier]": BUNDLE_ID, "limit": 5})
    data = api("GET", f"/v1/bundleIds?{q}", token)
    items = data.get("data") or []
    if not items:
        die(f"Bundle ID {BUNDLE_ID} not found in App Store Connect")
    return items[0]


def ensure_apple_signin_capability(token: str, bundle_res_id: str) -> None:
    q = urllib.parse.urlencode({"limit": 50})
    caps = api("GET", f"/v1/bundleIds/{bundle_res_id}/bundleIdCapabilities?{q}", token)
    for cap in caps.get("data") or []:
        if (cap.get("attributes") or {}).get("capabilityType") == "APPLE_ID_AUTH":
            print("Sign in with Apple capability already on Bundle ID")
            return
    print("Enabling Sign in with Apple on Bundle ID…")
    body = {
        "data": {
            "type": "bundleIdCapabilities",
            "attributes": {
                "capabilityType": "APPLE_ID_AUTH",
                "settings": [
                    {
                        "key": "APPLE_ID_AUTH_APP_CONSENT",
                        "options": [{"key": "PRIMARY_APP_CONSENT", "enabled": True}],
                    }
                ],
            },
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_res_id}}
            },
        }
    }
    api("POST", "/v1/bundleIdCapabilities", token, body)
    print("Sign in with Apple capability enabled")


def find_distribution_cert(token: str) -> str:
    q = urllib.parse.urlencode(
        {
            "filter[certificateType]": "DISTRIBUTION,IOS_DISTRIBUTION",
            "limit": 50,
        }
    )
    # API may not accept comma filter — try DISTRIBUTION then IOS_DISTRIBUTION
    for ctype in ("DISTRIBUTION", "IOS_DISTRIBUTION"):
        q = urllib.parse.urlencode({"filter[certificateType]": ctype, "limit": 20})
        data = api("GET", f"/v1/certificates?{q}", token)
        items = data.get("data") or []
        if items:
            cid = items[0]["id"]
            print(f"Using distribution certificate id={cid} type={ctype}")
            return cid
    die("No DISTRIBUTION certificate found via ASC API")


def create_profile(token: str, bundle_res_id: str, cert_id: str) -> dict:
    name = f"Gonggi App Store SIWA {int(time.time())}"
    body = {
        "data": {
            "type": "profiles",
            "attributes": {
                "name": name,
                "profileType": "IOS_APP_STORE",
            },
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_res_id}},
                "certificates": {
                    "data": [{"type": "certificates", "id": cert_id}]
                },
            },
        }
    }
    print(f"Creating profile {name}…")
    return api("POST", "/v1/profiles", token, body)


def download_profile(token: str, profile_id: str) -> bytes:
    data = api("GET", f"/v1/profiles/{profile_id}", token)
    b64 = (data.get("data") or {}).get("attributes", {}).get("profileContent")
    if not b64:
        die("profileContent missing from ASC response")
    return base64.b64decode(b64)


def profile_has_signin(profile_bytes: bytes) -> bool:
    # Entitlements appear as plaintext-ish inside CMS; simple needle check is enough.
    return b"com.apple.developer.applesignin" in profile_bytes


def main() -> None:
    token = make_token()
    bundle = find_bundle(token)
    bundle_res_id = bundle["id"]
    print(f"Bundle resource id={bundle_res_id} team={TEAM_ID}")
    ensure_apple_signin_capability(token, bundle_res_id)
    cert_id = find_distribution_cert(token)
    created = create_profile(token, bundle_res_id, cert_id)
    profile_id = created["data"]["id"]
    attrs = created["data"].get("attributes") or {}
    profile_name = attrs.get("name") or "Gonggi App Store"
    raw = download_profile(token, profile_id)
    if not profile_has_signin(raw):
        die("Newly created profile still missing com.apple.developer.applesignin")
    OUT_PROFILE.parent.mkdir(parents=True, exist_ok=True)
    OUT_PROFILE.write_bytes(raw)
    meta = {
        "profile_id": profile_id,
        "profile_name": profile_name,
        "bundle_id": BUNDLE_ID,
        "has_applesignin": True,
        "bytes": len(raw),
    }
    OUT_META.write_text(json.dumps(meta, indent=2), encoding="utf-8")
    # GitHub Actions outputs
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a", encoding="utf-8") as f:
            f.write(f"profile_name={profile_name}\n")
            f.write(f"profile_path={OUT_PROFILE}\n")
    print(f"Wrote profile ({len(raw)} bytes) name={profile_name}")
    print("PASS: profile includes Sign in with Apple")


if __name__ == "__main__":
    main()
