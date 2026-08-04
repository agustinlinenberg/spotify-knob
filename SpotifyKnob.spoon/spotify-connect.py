#!/usr/bin/env python3
"""
Spotify Connect bridge for the PowerMate knob.

Talks to the Spotify Web API so playback can be pushed to a Connect speaker
(Sonos/Cast/etc.) and controlled from there. Spotify's AppleScript interface
only controls the local Mac app, which is useless once audio is on a speaker.

Credentials live in the macOS Keychain -- never in this file, never in the
Hammerspoon config. You put them there yourself; this script only reads them.

    security add-generic-password -s spotify-knob -a client_id     -w 'YOUR_ID'
    security add-generic-password -s spotify-knob -a client_secret -w 'YOUR_SECRET'

Then authorise once:   ./spotify-connect.py auth

Commands:
    auth                 one-time OAuth, stores a refresh token in the Keychain
    devices              list available Connect devices
    transfer <name>      move playback to a device (substring match, case-insensitive)
    volume <0-100>       set volume on the active device
    playpause            toggle playback
    state                active device name + volume, as "name|volume|is_playing"

Requires Spotify Premium: the playback endpoints are Premium-only.
"""

import base64
import http.server
import json
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

SERVICE = "spotify-knob"
REDIRECT = "http://127.0.0.1:8888/callback"
SCOPES = "user-read-playback-state user-modify-playback-state"
TOKEN_CACHE = "/tmp/.spotify-knob-token"


# --- keychain -------------------------------------------------------------

def kc_get(account):
    try:
        return subprocess.check_output(
            ["security", "find-generic-password", "-s", SERVICE, "-a", account, "-w"],
            stderr=subprocess.DEVNULL, text=True).strip()
    except subprocess.CalledProcessError:
        return None


def kc_set(account, value):
    subprocess.run(["security", "delete-generic-password", "-s", SERVICE, "-a", account],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["security", "add-generic-password", "-s", SERVICE, "-a", account,
                    "-w", value], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def credentials():
    cid, secret = kc_get("client_id"), kc_get("client_secret")
    if not cid or not secret:
        die("No credentials in Keychain. See the header of this file for the "
            "two `security add-generic-password` commands.")
    return cid, secret


def die(msg):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


# --- tokens ---------------------------------------------------------------

def basic_auth_header():
    cid, secret = credentials()
    blob = base64.b64encode(f"{cid}:{secret}".encode()).decode()
    return {"Authorization": "Basic " + blob}


def post_token(payload):
    data = urllib.parse.urlencode(payload).encode()
    req = urllib.request.Request("https://accounts.spotify.com/api/token",
                                 data=data, headers=basic_auth_header())
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        die(f"token request failed ({e.code}): {e.read().decode()[:200]}")


def access_token():
    """Cached access token, refreshed when close to expiry."""
    try:
        with open(TOKEN_CACHE) as f:
            cached = json.load(f)
        if cached["expires_at"] - time.time() > 60:
            return cached["access_token"]
    except (OSError, ValueError, KeyError):
        pass

    credentials()  # fail on missing client_id/secret before blaming authorisation
    refresh = kc_get("refresh_token")
    if not refresh:
        die("Not authorised yet. Run: spotify-connect.py auth")

    tok = post_token({"grant_type": "refresh_token", "refresh_token": refresh})
    save_token(tok)
    if tok.get("refresh_token"):
        kc_set("refresh_token", tok["refresh_token"])
    return tok["access_token"]


def save_token(tok):
    blob = {"access_token": tok["access_token"],
            "expires_at": time.time() + tok.get("expires_in", 3600)}
    import os
    fd = os.open(TOKEN_CACHE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(blob, f)


# --- api ------------------------------------------------------------------

def api(method, path, params=None, body=None, allow_fail=False):
    url = "https://api.spotify.com/v1" + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "Bearer " + access_token(),
        "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read()
            # The playback endpoints (play/pause/volume/transfer) answer 204 with
            # an empty or non-JSON body. Only /me/player and /devices return JSON,
            # so a body that won't parse is success, not failure.
            if not raw or not raw.strip():
                return {}
            try:
                return json.loads(raw)
            except ValueError:
                return {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:200]
        if allow_fail:
            return None          # caller decides how to recover
        if e.code == 403:
            die(f"403 from Spotify -- these endpoints require Premium. {detail}")
        if e.code == 404:
            die("404 -- no active Spotify device. Start playback somewhere first.")
        die(f"{e.code}: {detail}")


# --- oauth ----------------------------------------------------------------

def cmd_auth():
    cid, _ = credentials()
    state = secrets.token_urlsafe(16)
    got = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            got.update({k: v[0] for k, v in q.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            ok = "code" in got and got.get("state") == state
            self.wfile.write(b"<h2>Authorised. Close this tab.</h2>" if ok
                             else b"<h2>Authorisation failed.</h2>")

        def log_message(self, *a):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 8888), Handler)
    threading.Thread(target=server.handle_request, daemon=True).start()

    url = "https://accounts.spotify.com/authorize?" + urllib.parse.urlencode({
        "client_id": cid, "response_type": "code", "redirect_uri": REDIRECT,
        "scope": SCOPES, "state": state})
    print("Opening browser to authorise...")
    subprocess.run(["open", url])

    for _ in range(120):
        if got:
            break
        time.sleep(1)

    if got.get("state") != state or "code" not in got:
        die("authorisation did not complete (state mismatch or timeout)")

    tok = post_token({"grant_type": "authorization_code", "code": got["code"],
                      "redirect_uri": REDIRECT})
    kc_set("refresh_token", tok["refresh_token"])
    save_token(tok)
    print("Authorised. Refresh token stored in Keychain.")


# --- commands -------------------------------------------------------------

def cmd_devices():
    for d in api("GET", "/me/player/devices").get("devices", []):
        mark = "*" if d["is_active"] else " "
        vol = d.get("volume_percent")
        print(f'{mark} {d["name"]}  [{d["type"]}]  vol={vol}  id={d["id"]}')


def find_device(needle):
    devices = api("GET", "/me/player/devices").get("devices", [])
    for d in devices:
        if needle.lower() in d["name"].lower():
            return d
    die("no Connect device matching %r. Available: %s"
        % (needle, ", ".join(d["name"] for d in devices) or "none"))


def cmd_transfer(needle):
    d = find_device(needle)
    # play=False keeps whatever state playback is already in. Forcing True means
    # merely switching modes would blast music into the room unannounced.
    api("PUT", "/me/player", body={"device_ids": [d["id"]], "play": False})
    print(f'transferred to {d["name"]}')


def cmd_volume(pct):
    pct = max(0, min(100, int(pct)))
    api("PUT", "/me/player/volume", params={"volume_percent": pct})
    print(pct)


def cmd_playpause(device=None):
    """Toggle playback, waking `device` if Spotify has deactivated everything.

    Spotify drops a device from 'active' once it has been paused a while, and
    every playback call then 404s. Passing a device name lets us wake it and
    retry instead of dumping a dead-end error on the user.
    """
    st = api("GET", "/me/player", allow_fail=True)
    pausing = bool(st and st.get("is_playing"))
    path = "/me/player/pause" if pausing else "/me/player/play"

    if api("PUT", path, allow_fail=True) is not None:
        print("paused" if pausing else "playing")
        return

    if not device:
        die("404 -- no active Spotify device. Start playback somewhere first.")

    d = find_device(device)
    api("PUT", "/me/player", body={"device_ids": [d["id"]], "play": False})
    # Nothing was playing (that is why it was asleep), so resume rather than
    # re-toggling off whatever stale state we read a moment ago.
    api("PUT", "/me/player/play")
    print("playing")


def _art_url(st, min_px=160):
    """Smallest cover at least `min_px` wide, or the largest on offer.

    The card draws it at 72pt, so 160px covers a 2x display with room to spare
    and anything larger is a slower download for pixels nobody sees. Tracks
    carry art on the album; podcast episodes carry it on the show instead.
    """
    item = st.get("item") or {}
    imgs = (
        (item.get("album") or {}).get("images")
        or (item.get("show") or {}).get("images")
        or item.get("images")
        or []
    )
    if not imgs:
        return ""
    ranked = sorted(imgs, key=lambda i: i.get("width") or 0)
    for i in ranked:
        if (i.get("width") or 0) >= min_px:
            return i.get("url") or ""
    return ranked[-1].get("url") or ""


def cmd_state():
    """Everything the card draws, as JSON.

    This used to be three pipe-separated fields. The card needs title, artist,
    artwork and progress as well, and at seven fields a positional string stops
    being something you can read at a glance or extend without breaking the
    parser on the other side.
    """
    st = api("GET", "/me/player")
    if not st or not st.get("device"):
        print(json.dumps({"device": "", "volume": 0, "playing": False}))
        return

    d = st["device"]
    item = st.get("item") or {}
    # Tracks list artists; podcast episodes name a single show instead.
    artists = ", ".join(a.get("name", "") for a in (item.get("artists") or []))
    if not artists:
        artists = (item.get("show") or {}).get("name", "")

    print(json.dumps({
        "device":   d.get("name", ""),
        "volume":   d.get("volume_percent", 0),
        "playing":  bool(st.get("is_playing", False)),
        "title":    item.get("name", ""),
        "artist":   artists,
        "art":      _art_url(st),
        "progress": st.get("progress_ms") or 0,
        "duration": item.get("duration_ms") or 0,
    }))


def cmd_skip(direction):
    """Previous / next track.

    Spotify answers these with 204 and no body, so there is nothing to echo
    back; the caller re-reads state once the change has landed.
    """
    endpoint = "next" if direction == "next" else "previous"
    api("POST", f"/me/player/{endpoint}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd, args = sys.argv[1], sys.argv[2:]
    table = {"auth": cmd_auth, "devices": cmd_devices, "transfer": cmd_transfer,
             "volume": cmd_volume, "playpause": cmd_playpause, "state": cmd_state,
             "next": lambda: cmd_skip("next"), "prev": lambda: cmd_skip("prev")}
    if cmd not in table:
        die(f"unknown command {cmd!r}")
    table[cmd](*args)


if __name__ == "__main__":
    main()
