#!/usr/bin/env python3
"""Gives an uploaded build to the external TestFlight group and submits it for beta review.

Usage: scripts/distribute.py <build number> [what to test]

Waits until App Store Connect has processed the build, sets the "What to Test" text
(English and Dutch get the same text), adds the build to the external group "Testers"
and submits it for Beta App Review. Without a text, the commit subjects since the
previous distributed build are used (git tag "testflight-external").
Uses the App Store Connect API key in ~/.appstoreconnect/private_keys.
"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request

KEY_ID = "TDLK875PQH"
ISSUER = "69a6de8f-8c00-47e3-e053-5b8c7c11a4d1"
BUNDLE_ID = "nl.wiebenieuwenhuis.frigate"
GROUP = "Testers"
KEY = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")
TAG = "testflight-external"


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token() -> str:
    header = b64(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
    now = int(time.time())
    payload = b64(json.dumps({"iss": ISSUER, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"}).encode())
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", KEY], input=f"{header}.{payload}".encode(),
                         capture_output=True, check=True).stdout
    # DER signature -> raw r||s
    i = 2 if der[1] < 0x80 else 3
    rl = der[i + 1]; r = der[i + 2:i + 2 + rl]; j = i + 2 + rl
    sl = der[j + 1]; s = der[j + 2:j + 2 + sl]
    signature = r[-32:].rjust(32, bytes(1)) + s[-32:].rjust(32, bytes(1))
    return f"{header}.{payload}.{b64(signature)}"


def api(method: str, path: str, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, (json.loads(raw) if raw else {})


def must(result, what):
    status, data = result
    if status >= 300:
        sys.exit(f"{what} failed ({status}): {json.dumps(data.get('errors', data))[:600]}")
    return data


def what_to_test() -> str:
    has_tag = subprocess.run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{TAG}"], capture_output=True).returncode == 0
    rng = [f"{TAG}..HEAD"] if has_tag else ["-15"]
    log = subprocess.run(["git", "log", "--format=- %s", *rng], capture_output=True, text=True).stdout.strip()
    return log or "Bug fixes and improvements."


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    version = sys.argv[1]
    text = sys.argv[2] if len(sys.argv) > 2 else what_to_test()
    text = text[:4000]

    app = must(api("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}"), "Find app")["data"][0]["id"]

    print(f"Waiting for build {version} to finish processing…", flush=True)
    build = None
    for _ in range(90):
        data = must(api("GET", f"/v1/builds?filter[app]={app}&filter[version]={version}"), "Find build")["data"]
        if data:
            state = data[0]["attributes"]["processingState"]
            if state == "VALID":
                build = data[0]
                break
            if state in ("FAILED", "INVALID"):
                sys.exit(f"Build {version} is {state}")
        time.sleep(20)
    if not build:
        sys.exit("Build did not finish processing in 30 minutes")
    build_id = build["id"]

    if build["attributes"].get("usesNonExemptEncryption") is None:
        must(api("PATCH", f"/v1/builds/{build_id}", {"data": {"type": "builds", "id": build_id,
             "attributes": {"usesNonExemptEncryption": False}}}), "Set export compliance")

    existing = must(api("GET", f"/v1/builds/{build_id}/betaBuildLocalizations"), "Read What to Test")["data"]
    by_locale = {loc["attributes"]["locale"]: loc["id"] for loc in existing}
    for locale in ("en-US", "nl-NL"):
        if locale in by_locale:
            must(api("PATCH", f"/v1/betaBuildLocalizations/{by_locale[locale]}", {"data": {
                "type": "betaBuildLocalizations", "id": by_locale[locale], "attributes": {"whatsNew": text}}}), "Update What to Test")
        else:
            must(api("POST", "/v1/betaBuildLocalizations", {"data": {
                "type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": text},
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}}), "Set What to Test")

    groups = must(api("GET", f"/v1/apps/{app}/betaGroups"), "Find groups")["data"]
    group = next((g for g in groups if g["attributes"]["name"] == GROUP and not g["attributes"]["isInternalGroup"]), None)
    if not group:
        sys.exit(f'No external TestFlight group named "{GROUP}"')
    # The group side of this relationship answers 404 for this key; the build side works.
    must(api("POST", f"/v1/builds/{build_id}/relationships/betaGroups",
             {"data": [{"type": "betaGroups", "id": group["id"]}]}), "Add build to group")

    status, data = api("POST", "/v1/betaAppReviewSubmissions",
                       {"data": {"type": "betaAppReviewSubmissions",
                                 "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    if status >= 300:
        codes = " ".join(e.get("code", "") + " " + e.get("detail", "") for e in data.get("errors", []))
        if "already" in codes.lower():
            print("Already submitted for beta review.")
        else:
            sys.exit(f"Submit for beta review failed ({status}): {codes[:600]}")
    else:
        print("Submitted for beta review.")

    subprocess.run(["git", "tag", "-f", TAG, "HEAD"], capture_output=True)
    print(f'Build {version} is in group "{GROUP}". Testers get it once Apple approves the beta review.')


if __name__ == "__main__":
    main()
