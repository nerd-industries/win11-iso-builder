"""Windows ISO download server.

Single FastAPI app. Auth via a single shared password through any of:
  1. Signed cookie (browser, post-login)
  2. HTTP Basic auth (download managers — username field ignored)
  3. ?token=<password> query string

Serves /srv/iso/ with HTTP Range support so 5-6 GB ISOs resume cleanly.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import os
import time
from pathlib import Path

from fastapi import FastAPI, Form, Request, HTTPException
from fastapi.responses import (
    FileResponse,
    HTMLResponse,
    RedirectResponse,
    Response,
)
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

# ─── Configuration (env-driven) ──────────────────────────────────────────────
# Passwords come from ISO_PASSWORDS (colon-separated list) and/or ISO_PASSWORD
# (single, kept for backwards compat). All entries are accepted by all three
# auth doors. Comparisons use hmac.compare_digest in any_password_matches().
_pw_list = os.environ.get("ISO_PASSWORDS", "").split(":") + [os.environ.get("ISO_PASSWORD", "")]
PASSWORDS = tuple(p for p in _pw_list if p)
if not PASSWORDS:
    raise RuntimeError("Set ISO_PASSWORD and/or ISO_PASSWORDS in env")
# Kept for legacy import compat — represents "any" password
PASSWORD = PASSWORDS[0]


def any_password_matches(candidate: str) -> bool:
    """Constant-time compare against the full password set.

    Always compares against every entry (no short-circuit) so total time
    doesn't reveal which password matched or how many entries exist.
    """
    if not candidate:
        return False
    matched = False
    for pw in PASSWORDS:
        if hmac.compare_digest(candidate, pw):
            matched = True
    return matched


COOKIE_SECRET = os.environ["ISO_COOKIE_SECRET"].encode()
ISO_DIR = Path(os.environ["ISO_DIR"])
PUBLIC_URL = os.environ.get("PUBLIC_URL", "")
COOKIE_NAME = "iso_auth"
COOKIE_MAX_AGE = 7 * 24 * 3600  # 7 days

BASE_DIR = Path(__file__).parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


# ─── Cookie HMAC helpers ─────────────────────────────────────────────────────
def _b64encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _b64decode(data: str) -> bytes:
    pad = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + pad)


def make_cookie() -> str:
    """Encode 'expiry_ts.signature'."""
    expiry = int(time.time()) + COOKIE_MAX_AGE
    payload = str(expiry).encode()
    sig = hmac.new(COOKIE_SECRET, payload, hashlib.sha256).digest()
    return f"{_b64encode(payload)}.{_b64encode(sig)}"


def verify_cookie(cookie: str) -> bool:
    try:
        payload_b64, sig_b64 = cookie.split(".", 1)
        payload = _b64decode(payload_b64)
        sig = _b64decode(sig_b64)
        expected = hmac.new(COOKIE_SECRET, payload, hashlib.sha256).digest()
        if not hmac.compare_digest(sig, expected):
            return False
        expiry = int(payload.decode())
        return expiry > int(time.time())
    except Exception:
        return False


# ─── Three-door auth predicate ───────────────────────────────────────────────
def authed(request: Request) -> bool:
    # 1. Signed cookie
    cookie = request.cookies.get(COOKIE_NAME)
    if cookie and verify_cookie(cookie):
        return True

    # 2. HTTP Basic auth — username ignored, password compared constant-time
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("basic "):
        try:
            decoded = base64.b64decode(auth[6:]).decode()
            _, _, pw = decoded.partition(":")
            if any_password_matches(pw):
                return True
        except Exception:
            pass

    # 3. Query token
    token = request.query_params.get("token", "")
    if any_password_matches(token):
        return True

    return False


def require_auth_or_redirect(request: Request) -> RedirectResponse | None:
    if authed(request):
        return None
    return RedirectResponse("/login", status_code=303)


# ─── Routes ──────────────────────────────────────────────────────────────────
@app.get("/", response_class=RedirectResponse)
def root(request: Request):
    if authed(request):
        return RedirectResponse("/list", status_code=303)
    return RedirectResponse("/login", status_code=303)


@app.get("/login", response_class=HTMLResponse)
def login_get(request: Request):
    return templates.TemplateResponse(
        request, "login.html", {"error": None}
    )


@app.post("/login")
def login_post(request: Request, password: str = Form(...)):
    if not any_password_matches(password):
        # Re-render with error — 401 status so tests can assert
        return HTMLResponse(
            templates.get_template("login.html").render(
                request=request, error="Incorrect password."
            ),
            status_code=401,
        )
    resp = RedirectResponse("/list", status_code=303)
    resp.set_cookie(
        COOKIE_NAME,
        make_cookie(),
        max_age=COOKIE_MAX_AGE,
        httponly=True,
        samesite="lax",
        secure=True,
    )
    return resp


@app.get("/logout")
def logout():
    resp = RedirectResponse("/login", status_code=303)
    resp.delete_cookie(COOKIE_NAME)
    return resp


@app.get("/list")
def list_isos(request: Request):
    redirect = require_auth_or_redirect(request)
    if redirect:
        return redirect
    # Show the current + previous feature update during a version transition
    # (e.g. 25H2 and 26H2). Matches Win11-25H2/26H2-Pro-*-RST-Rufus.iso.
    isos = sorted(
        ISO_DIR.glob("Win11-2[56]H2-Pro-*-RST-Rufus.iso"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    rows = []
    for p in isos:
        st = p.stat()
        rows.append({
            "name": p.name,
            "size_human": _human_size(st.st_size),
            "mtime_human": time.strftime("%Y-%m-%d %H:%M", time.gmtime(st.st_mtime)),
        })
    return templates.TemplateResponse(
        request, "list.html", {"isos": rows, "public_url": PUBLIC_URL}
    )


def _human_size(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


@app.get("/iso/{name}")
def download_iso(request: Request, name: str):
    redirect = require_auth_or_redirect(request)
    if redirect:
        return redirect
    # Resolve and verify the result is actually inside ISO_DIR.
    # is_relative_to is symlink-safe and immune to URL-encoding tricks.
    iso_root = ISO_DIR.resolve()
    try:
        p = (iso_root / name).resolve()
    except (OSError, ValueError):
        raise HTTPException(404)
    if not p.is_file() or not p.is_relative_to(iso_root):
        raise HTTPException(404)
    # FileResponse in Starlette ≥0.45 handles HTTP Range natively (incl. suffix
    # ranges, EOF clamping, multipart/byteranges, 416 with Content-Range:*).
    return FileResponse(
        path=str(p),
        media_type="application/octet-stream",
        filename=p.name,
    )
