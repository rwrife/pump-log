#!/usr/bin/env python3
"""Bounded ASC processing poll, only used by manually dispatched release CI."""
import base64
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.appstoreconnect.apple.com"


def b64(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def der_to_raw(der):
    # P-256 ECDSA DER signatures fit in a short-form SEQUENCE.
    if len(der) < 8 or der[0] != 0x30 or der[1] != len(der) - 2:
        raise ValueError("Invalid ECDSA signature sequence")
    offset = 2
    values = []
    for _ in range(2):
        if der[offset] != 2:
            raise ValueError("Invalid ECDSA signature integer")
        size = der[offset + 1]
        value = der[offset + 2:offset + 2 + size]
        if len(value) != size or size == 0 or value[0] & 0x80:
            raise ValueError("Invalid ECDSA integer encoding")
        value = value.lstrip(b"\0")
        if len(value) > 32:
            raise ValueError("Signature is not P-256")
        values.append(value.rjust(32, b"\0"))
        offset += 2 + size
    if offset != len(der):
        raise ValueError("Trailing ECDSA signature bytes")
    return b"".join(values)


def token(key):
    now = int(time.time())
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    claims = {"iss": os.environ["ASC_ISSUER_ID"], "aud": "appstoreconnect-v1", "iat": now, "exp": now + 600}
    message = (b64(json.dumps(header).encode()) + "." + b64(json.dumps(claims).encode())).encode()
    signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key)], input=message,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=15).stdout
    return message.decode() + "." + b64(der_to_raw(signature))


def api(path, query, key):
    url = API + path + "?" + urllib.parse.urlencode(query)
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token(key)})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)["data"]
    except urllib.error.HTTPError as error:
        # Never log Authorization or a signed JWT.
        raise RuntimeError(f"ASC {path}: HTTP {error.code}; check app record/API-key permissions") from None


def find_build(builds, number, version):
    matches = [b for b in builds if b.get("attributes", {}).get("version") == number
               and b.get("relationships", {}).get("preReleaseVersion", {}).get("data", {}).get("id")]
    if len(matches) > 1:
        raise ValueError(f"Multiple ASC builds match {version} ({number})")
    return matches[0] if matches else None


def poll(fetch, number, version, timeout=900, clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + timeout
    while clock() < deadline:
        build = find_build(fetch(), number, version)
        if build:
            state = build["attributes"].get("processingState")
            print(f"ASC build {build['id']}: {version} ({number}), processingState={state}", flush=True)
            if state in {"VALID", "COMPLETE"}:
                # Apple's current API calls processed builds VALID; normalize the
                # acceptance stage but always preserve the real response state.
                return {"build_id": build["id"], "build_number": number, "marketing_version": version,
                        "processingState": state, "processing_stage": "COMPLETE"}
            if state != "PROCESSING":
                raise ValueError(f"ASC processing failed or unexpected state: {state!r}")
        sleep(min(30, max(0, deadline - clock())))
    raise TimeoutError(f"No processed ASC build {version} ({number}) within {timeout}s")


def main():
    key = Path(os.environ["RUNNER_TEMP"]) / "pump-log-asc/AuthKey.p8"
    evidence = json.loads(Path("build/release/archive-evidence.json").read_text())
    version = evidence["marketing_version"]
    number = os.environ["GITHUB_RUN_NUMBER"]
    apps = api("/v1/apps", {"filter[bundleId]": "com.infinityball.pumplog"}, key)
    if len(apps) != 1:
        raise ValueError("Expected exactly one ASC app record for com.infinityball.pumplog; create it before release")
    app_id = apps[0]["id"]
    query = {"filter[app]": app_id, "filter[version]": number,
             "filter[preReleaseVersion.version]": version, "include": "preReleaseVersion", "limit": "50"}
    result = poll(lambda: api("/v1/builds", query, key), number, version)
    result.update(app_id=app_id, commit_sha=os.environ["GITHUB_SHA"], run_url=os.environ["RELEASE_RUN_URL"])
    Path("build/release/processed-build.json").write_text(json.dumps(result, indent=2) + "\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
        summary.write("\n## Real processed TestFlight build\n```json\n" + json.dumps(result, indent=2) + "\n```\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
