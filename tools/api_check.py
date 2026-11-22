#!/usr/bin/env python3
"""Phase 0: checks the server and plugin API the app relies on (see PLAN.md, section 3).

    python3 tools/api_check.py <base url> <rc-photo.zip> <photo.jpg> [<video.mp4>]

Needs a fresh RustCloud (no accounts yet): it registers the admin, installs the plugin,
then does everything else as the app would — with the access token of an app login
(OAuth + PKCE, redirect_uri = com.rustcloud.photos:/callback). Only the standard library.
"""

import base64
import hashlib
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE, ZIP, PHOTO = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
VIDEO = sys.argv[4] if len(sys.argv) > 4 else None
REDIRECT = "com.rustcloud.photos:/callback"
COUNT = int(os.environ.get("PHOTOS", "300"))
results = []


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


opener = urllib.request.build_opener(NoRedirect)


def call(method, path, token=None, body=None, raw=None, ctype=None, headers=None):
    """(status, headers, bytes)."""
    url = path if path.startswith("http") else BASE + path
    data = raw
    hdrs = {"X-Requested-With": "rc-photo-client-check"}
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    if ctype:
        hdrs["Content-Type"] = ctype
    if token:
        hdrs["Authorization"] = f"Bearer {token}"
    hdrs.update(headers or {})
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with opener.open(req, timeout=120) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def js(method, path, token=None, body=None, **kw):
    status, _, data = call(method, path, token, body, **kw)
    try:
        return status, json.loads(data) if data else None
    except ValueError:
        return status, data.decode(errors="replace")


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(f"[{'OK' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""), flush=True)
    return ok


def must(name, status, want, data):
    if status != want:
        print(f"[ABORT] {name}: {status} {data}")
        sys.exit(2)
    return data


# ── Setup as the admin (the app never does this) ────────────────────────
_, admin = js("POST", "/api/v1/auth/register", body={"username": "admin", "password": "password123"})
admin = admin["token"]
st, inst = js("POST", "/api/v1/admin/plugins", admin, raw=open(ZIP, "rb").read(), ctype="application/zip")
must("install plugin", 201 if st in (200, 201) else st, 201, inst)
st, en = js("PUT", "/api/v1/admin/plugins/rc-photo", admin, body={"enabled": True})
must("enable plugin", st, 200, en)
print(f"plugin: {inst.get('version') if isinstance(inst, dict) else inst}")

# ── 1. App login: OAuth 2.0 + PKCE with the app's own scheme ─────────────
verifier = secrets.token_urlsafe(48)
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
q = {
    "client_id": "rc-photo-client", "device_name": "api-check", "redirect_uri": REDIRECT,
    "code_challenge": challenge, "code_challenge_method": "S256", "state": "xyz",
}
st, hd, _ = call("GET", "/api/v1/auth/authorize?" + urllib.parse.urlencode(q))
loc = hd.get("location") or hd.get("Location") or ""
check("1a authorize accepts the app scheme as redirect_uri", st in (302, 303, 307) and "invalid" not in loc, f"{st} → {loc[:60]}")
st, code = js("POST", "/api/v1/auth/authorize", admin, body={k: v for k, v in q.items() if k != "state"})
code = must("authorize (consent)", st, 200, code)["code"]
form = urllib.parse.urlencode({"grant_type": "authorization_code", "code": code, "code_verifier": verifier, "redirect_uri": REDIRECT}).encode()
st, tok = js("POST", "/api/v1/auth/token", raw=form, ctype="application/x-www-form-urlencoded")
check("1b code → tokens", st == 200 and "access_token" in tok, f"expires_in={tok.get('expires_in') if isinstance(tok, dict) else tok}")
access, refresh = tok["access_token"], tok["refresh_token"]

# refresh rotation; a quick retry with the old one (< 30 s) must not end the session
form = urllib.parse.urlencode({"grant_type": "refresh_token", "refresh_token": refresh}).encode()
st, tok2 = js("POST", "/api/v1/auth/token", raw=form, ctype="application/x-www-form-urlencoded")
check("1c refresh gives a new pair", st == 200 and tok2["refresh_token"] != refresh)
st, tok3 = js("POST", "/api/v1/auth/token", raw=form, ctype="application/x-www-form-urlencoded")
check("1d old refresh within 30 s (retry after a lost reply)", True, f"{st} {str(tok3)[:80]}")
access, refresh = tok2["access_token"], tok2["refresh_token"]
st, me = js("GET", "/api/v1/auth/me", access)
check("1e new access works after the retry", st == 200, f"{st}")
st, info = js("GET", "/api/v1/info")
check("1f GET /api/v1/info", st == 200, json.dumps(info, ensure_ascii=False)[:200])

# ── 5. Folder + grant from the app token ────────────────────────────────
st, root = js("GET", "/api/v1/files/root", access)
root = must("root", st, 200, root)["id"]
st, folder = js("POST", f"/api/v1/files/{root}/folders", access, body={"name": "Фото"})
folder = must("folder", st, 201, folder)["id"]
st, sub = js("POST", f"/api/v1/files/{folder}/folders", access, body={"name": "Pixel 8"})
sub = must("subfolder", st, 201, sub)["id"]
st, g = js("POST", "/api/v1/grants", access, body={"app_id": "rc-photo", "node_id": sub, "write": True, "kind": "standing"})
check("5 POST /api/v1/grants with the app token", st in (200, 201), f"{st} {str(g)[:120]}")

# ── 2. state with Bearer ────────────────────────────────────────────────
st, state = js("GET", "/app/rc-photo/api/state", access)
check("2a /app/rc-photo/api/state with Bearer", st == 200 and isinstance(state, dict) and "shards" in state, f"{st} {str(state)[:200]}")
if st == 200:
    check("2b state lists the granted folder", any(f["id"] == sub for f in state["folders"]), str(state["folders"]))

# ── 4. Uploads: simple ones and one in parts ─────────────────────────────
jpeg = open(PHOTO, "rb").read()
t0 = time.time()
hashes = {}
for i in range(COUNT):
    data = jpeg + f"\n{i}".encode()  # bytes after EOI keep the JPEG valid, change the hash
    mtime = urllib.parse.quote(f"2024-0{1 + i % 9}-1{i % 10}T12:00:00Z")
    st, node = js("POST", f"/api/v1/files/{sub}/upload?name=IMG_{i:05}.jpg&mtime={mtime}", access, raw=data, ctype="application/octet-stream")
    if st != 201:
        check(f"4a upload #{i}", False, f"{st} {node}")
        break
    hashes[node["id"]] = hashlib.sha256(data).hexdigest()
    if i == 0:
        check("4b Node.etag == sha256 of the content", node.get("etag") == hashes[node["id"]], f"etag={node.get('etag')}")
print(f"uploaded {len(hashes)} photos in {time.time() - t0:.1f}s")

big = (jpeg + b"\nbig") * 1
st, up = js("POST", f"/api/v1/files/{sub}/uploads", access, body={"name": "BIG.jpg", "size": len(big)})
ok = st == 201
if ok:
    half = len(big) // 2
    st1, _ = js("PUT", f"/api/v1/files/uploads/{up['id']}?offset=0", access, raw=big[:half], ctype="application/octet-stream")
    st2, u2 = js("GET", f"/api/v1/files/uploads/{up['id']}", access)
    st3, _ = js("PUT", f"/api/v1/files/uploads/{up['id']}?offset={u2['received']}", access, raw=big[u2['received']:], ctype="application/octet-stream")
    st4, node = js("POST", f"/api/v1/files/uploads/{up['id']}/finish", access, body={"sha256": hashlib.sha256(big).hexdigest()})
    ok = st4 == 201
    if ok:
        hashes[node["id"]] = hashlib.sha256(big).hexdigest()
check("4c upload in parts (start, part, received, part, finish)", ok, f"{st}")

# name taken → 409 and the etag tells it's the same file
st, err = js("POST", f"/api/v1/files/{sub}/upload?name=IMG_00000.jpg", access, raw=jpeg + b"\n0", ctype="application/octet-stream")
check("4d same name → 409 NAME_TAKEN", st == 409, str(err)[:120])

# wait for the index
t0 = time.time()
entries = {}
while time.time() - t0 < 600:
    st, state = js("GET", "/app/rc-photo/api/state", access)
    entries = {}
    total_bytes = 0
    for url in state.get("shards", []):
        s, h, data = call("GET", url)  # no headers: the link alone must do
        if s == 200:
            total_bytes += len(data)
            for e in json.loads(data):
                entries[e["id"]] = e
    if len(entries) >= len(hashes):
        break
    time.sleep(3)
took = time.time() - t0
check("4e every upload is in the index", len(entries) >= len(hashes), f"{len(entries)}/{len(hashes)} in {took:.0f}s, progress={state.get('progress')}")
check("2c shard links download without headers", len(state.get("shards", [])) > 0, f"{len(state.get('shards', []))} shards")
if state.get("shards"):
    s, h, _ = call("GET", state["shards"][0])
    etag = h.get("ETag") or h.get("etag")
    s2, _, _ = call("GET", state["shards"][0], headers={"If-None-Match": etag} if etag else {})
    check("2d shard ETag + If-None-Match → 304", etag and s2 == 304, f"etag={etag} → {s2}; CORS={h.get('Access-Control-Allow-Origin')}")
same = sum(1 for i, e in entries.items() if hashes.get(i) == e.get("etag"))
check("4f Entry.etag == sha256 of the file", same == len(hashes), f"{same}/{len(hashes)}")
FIX = os.environ.get("FIXTURES")
if FIX and state.get("shards"):
    os.makedirs(FIX, exist_ok=True)
    json.dump(state, open(f"{FIX}/state.json", "w"), ensure_ascii=False, indent=1)
    json.dump(json.loads(call("GET", state["shards"][0])[2]), open(f"{FIX}/shard.json", "w"), ensure_ascii=False, indent=1)
    json.dump(js("GET", f"/api/v1/files/{sub}/children", access)[1][:3], open(f"{FIX}/children.json", "w"), ensure_ascii=False, indent=1)
    json.dump(js("POST", "/api/v1/files/root/upload?name=x", access, raw=b"")[1], open(f"{FIX}/error.json", "w"), ensure_ascii=False, indent=1)
if entries:
    per = total_bytes / len(entries)
    check("6 index size", True, f"{total_bytes} B for {len(entries)} entries ≈ {per:.0f} B/entry ≈ {per * 10000 / 1e6:.1f} MB per 10k photos (uncompressed)")
    print("sample entry:", json.dumps(next(iter(entries.values())), ensure_ascii=False))

# ── 3. links and stream ─────────────────────────────────────────────────
some = list(entries)[:3]
st, links = js("POST", "/app/rc-photo/api/links", access, body={"items": [{"id": i, "kind": k} for i in some for k in ("thumb", "original")]})
check("3a POST /app/rc-photo/api/links with Bearer", st == 200, f"{st} {str(links)[:150]}")
if st == 200:
    urls = links.get("urls", [])
    s, h, data = call("GET", urls[0])
    check("3b thumb link downloads without headers", s == 200, f"{s} {h.get('Content-Type')} {len(data)} B; cache={h.get('Cache-Control')}")
s, h, data = call("GET", f"/api/v1/files/{some[0]}/thumbnail", access)
check("3c server fallback /api/v1/files/{id}/thumbnail", s == 200, f"{s} {h.get('Content-Type')} {len(data)} B")

if VIDEO:
    st, node = js("POST", f"/api/v1/files/{sub}/upload?name=VID_0001.mp4", access, raw=open(VIDEO, "rb").read(), ctype="application/octet-stream")
    vid = node["id"]
    for _ in range(100):
        _, state = js("GET", "/app/rc-photo/api/state", access)
        found = False
        for url in state["shards"]:
            s, _, data = call("GET", url)
            if s == 200 and any(e["id"] == vid for e in json.loads(data)):
                found = True
        if found:
            break
        time.sleep(3)
    s, h, data = call("GET", f"/app/rc-photo/api/stream/{vid}?mode=copy", access)
    check("3d GET /app/rc-photo/api/stream/<id> with Bearer", s == 200, f"{s} {h.get('Content-Type')} {data[:120]!r}")

# ── changes feed ────────────────────────────────────────────────────────
st, ch = js("GET", "/api/v1/files/changes", access)
check("7 GET /api/v1/files/changes", st == 200, str(ch)[:150])

print()
failed = [r for r in results if not r[1]]
print(f"== {len(results) - len(failed)}/{len(results)} OK")
sys.exit(1 if failed else 0)
