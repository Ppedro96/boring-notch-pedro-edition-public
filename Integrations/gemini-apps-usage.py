"""Read Gemini Apps usage RPC, never conversations or generation endpoints.

Selected Google cookies stay in memory. Only Gemini usage endpoints are contacted.
References: TokenYou Gemini adapter and CodexBar iOS Gemini usage contract.
"""
import ctypes
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import pwd
import os
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://gemini.google.com"
RPC = "jSf9Qc"
SELECTED = {"__Secure-1PSID", "__Secure-1PSIDTS"}


class ProbeError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def configuration():
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    config = json.loads((home / ".pedroops/gemini-usage.json").read_text())
    profile = config.get("edgeProfile", "Default")
    account = config.get("expectedAccountHash", "")
    if not isinstance(profile, str) or not re.fullmatch(r"Default|Profile [0-9]+", profile):
        raise ProbeError("browser-profile-invalid")
    if not isinstance(account, str) or not re.fullmatch(r"[a-f0-9]{64}", account):
        raise ProbeError("expected-account-missing")
    return home, profile, account


def browser_session(home, profile):
    path = home / "Library/Application Support/Microsoft Edge" / profile / "Cookies"
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2) as conn:
        version = int(conn.execute("SELECT value FROM meta WHERE key='version'").fetchone()[0])
        rows = conn.execute(
            "SELECT host_key,name,value,encrypted_value FROM cookies "
            "WHERE host_key='.google.com' AND name IN ('__Secure-1PSID','__Secure-1PSIDTS')"
        ).fetchall()
    if not rows:
        raise ProbeError("browser-session-missing")
    try:
        secret = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-w", "-s", "Microsoft Edge Safe Storage"],
            capture_output=True, timeout=3, check=True,
        ).stdout.rstrip(b"\r\n")
    except Exception:
        raise ProbeError("browser-keychain-unavailable") from None
    key = hashlib.pbkdf2_hmac("sha1", secret, b"saltysalt", 1003, 16)
    crypto = ctypes.CDLL("/usr/lib/system/libcommonCrypto.dylib")
    decrypt = crypto.CCCrypt
    decrypt.argtypes = [ctypes.c_uint, ctypes.c_uint, ctypes.c_uint,
                        ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                        ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                        ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    decrypt.restype = ctypes.c_int
    values = {}
    for host, name, plain, encrypted in rows:
        if plain:
            value = plain
        else:
            if encrypted[:3] not in (b"v10", b"v11"):
                raise ProbeError("browser-cookie-format-unsupported")
            data = encrypted[3:]
            output = ctypes.create_string_buffer(len(data))
            count = ctypes.c_size_t()
            status = decrypt(1, 0, 1, key, len(key), b" " * 16, data, len(data),
                             output, len(data), ctypes.byref(count))
            if status != 0:
                raise ProbeError("browser-cookie-decryption-failed")
            decoded = output.raw[:count.value]
            if version >= 24:
                if decoded[:32] != hashlib.sha256(host.encode()).digest():
                    raise ProbeError("browser-cookie-host-mismatch")
                decoded = decoded[32:]
            value = decoded.decode()
        if not value or any(c in value for c in "\r\n;"):
            raise ProbeError("browser-cookie-invalid")
        values[name] = value
    if "__Secure-1PSID" not in values:
        raise ProbeError("browser-session-missing")
    return "; ".join(name + "=" + value for name, value in values.items())


def extract_token(html, name):
    match = re.search(r'"' + re.escape(name) + r'"\s*:\s*("(?:\\.|[^"\\])*")', html)
    return json.loads(match.group(1)) if match else None


def parse_usage(raw):
    rows = []
    for line in raw.splitlines():
        if '"wrb.fr"' in line:
            try:
                chunk = json.loads(line)
            except (ValueError, TypeError):
                continue
            if isinstance(chunk, list):
                rows.extend(row for row in chunk if isinstance(row, list) and len(row) >= 3
                            and row[0] == "wrb.fr" and row[1] == RPC)
    for row in rows:
        if len(row) > 5 and isinstance(row[5], list) and row[5] and row[5][0] == 7:
            raise ProbeError("gemini-session-rejected")
    windows = {}
    for row in rows:
        if not isinstance(row[2], str):
            continue
        try:
            payload = json.loads(row[2])
        except ValueError:
            continue
        if not isinstance(payload, list) or len(payload) < 2 or not isinstance(payload[1], list):
            continue
        for bucket in payload[1]:
            if not isinstance(bucket, list) or len(bucket) < 4:
                continue
            limit, fraction, period = bucket[:3]
            if type(fraction) not in (int, float) or not 0 <= fraction <= 1.5:
                continue
            if type(period) is not int or period not in (1, 2):
                continue
            if type(limit) not in (int, float) or limit <= 0:
                continue
            try:
                reset = bucket[3][0][0]
                if type(reset) not in (int, float) or reset < 1600000000:
                    continue
                nanos = bucket[3][0][1] if len(bucket[3][0]) > 1 else 0
                if type(nanos) not in (int, float) or not 0 <= nanos < 1000000000:
                    continue
            except (IndexError, TypeError):
                continue
            if period in windows:
                raise ProbeError("ambiguous-quota-buckets")
            windows[period] = {"usedPercent": min(100, int(fraction * 100 + 0.5)),
                               "resetsAtEpoch": reset + nanos / 1000000000}
    if set(windows) != {1, 2}:
        raise ProbeError("quota-format-incomplete")
    return {"current": windows[1], "weekly": windows[2]}


def probe():
    home, profile, expected_account = configuration()
    cookie = browser_session(home, profile)
    opener = urllib.request.build_opener(NoRedirect, urllib.request.ProxyHandler({}))
    headers = {"Cookie": cookie, "User-Agent": "PedroNotchUsageProbe/1.0", "Accept": "text/html"}
    request = urllib.request.Request(BASE + "/usage", headers=headers)
    with opener.open(request, timeout=10) as response:
        html = response.read(4000000).decode()
    email = extract_token(html, "oPEP7c")
    if not isinstance(email, str) or "@" not in email:
        raise ProbeError("account-identity-missing")
    account_hash = hashlib.sha256(email.strip().lower().encode()).hexdigest()
    if account_hash != expected_account:
        raise ProbeError("account-mismatch")
    at = extract_token(html, "SNlM0e")
    if not at:
        raise ProbeError("gemini-session-bootstrap-missing")
    params = {"rpcids": RPC, "source-path": "/usage", "hl": "en", "rt": "c"}
    for name, field in [("bl", "cfb2h"), ("f.sid", "FdrFJe")]:
        value = extract_token(html, field)
        if value:
            params[name] = value
    body = urllib.parse.urlencode({"at": at, "f.req": json.dumps([[[RPC, "[]", None, "generic"]]])}).encode()
    headers.update({"Content-Type": "application/x-www-form-urlencoded;charset=UTF-8", "Accept": "text/plain"})
    request = urllib.request.Request(BASE + "/_/BardChatUi/data/batchexecute?" + urllib.parse.urlencode(params),
                                     data=body, headers=headers, method="POST")
    with opener.open(request, timeout=10) as response:
        raw = response.read(1000000).decode()
    return {"ok": True, "source": "Gemini Apps RPC jSf9Qc", "accountHash": account_hash,
            "observedAtEpoch": time.time(), **parse_usage(raw)}


if __name__ == "__main__":
    try:
        result = probe()
    except ProbeError as e:
        result = {"ok": False, "error": str(e)}
    except urllib.error.HTTPError as e:
        result = {"ok": False, "error": "http-" + str(e.code)}
    except Exception:
        result = {"ok": False, "error": "probe-failed"}
    print(json.dumps(result))
