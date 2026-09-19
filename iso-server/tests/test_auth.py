"""Tests for the three-door auth predicate (cookie, Basic, ?token=)."""
import base64


def test_login_page_rendered(client):
    """GET /login returns 200 with a password form."""
    r = client.get("/login")
    assert r.status_code == 200
    assert 'name="password"' in r.text


def test_root_redirects_to_login_when_unauthed(client):
    r = client.get("/")
    assert r.status_code == 303
    assert r.headers["location"] == "/login"


def test_login_wrong_password_returns_401(client):
    r = client.post("/login", data={"password": "wrong"})
    assert r.status_code == 401


def test_login_correct_password_sets_cookie_and_redirects(client, env):
    r = client.post("/login", data={"password": env["ISO_PASSWORD"]})
    assert r.status_code == 303
    assert r.headers["location"] == "/list"
    assert "iso_auth" in r.cookies


def test_root_redirects_to_list_when_cookied(client, env):
    client.post("/login", data={"password": env["ISO_PASSWORD"]})
    r = client.get("/")
    assert r.status_code == 303
    assert r.headers["location"] == "/list"


def test_list_requires_auth_redirects_to_login(client):
    r = client.get("/list")
    assert r.status_code == 303
    assert r.headers["location"] == "/login"


def test_list_works_with_basic_auth(client, env, make_iso):
    make_iso("26200.8328")
    creds = base64.b64encode(f"any:{env['ISO_PASSWORD']}".encode()).decode()
    r = client.get("/list", headers={"Authorization": f"Basic {creds}"})
    assert r.status_code == 200


def test_list_works_with_query_token(client, env, make_iso):
    make_iso("26200.8328")
    r = client.get(f"/list?token={env['ISO_PASSWORD']}")
    assert r.status_code == 200


def test_list_rejects_wrong_basic_password(client, env):
    creds = base64.b64encode(b"any:wrong").decode()
    r = client.get("/list", headers={"Authorization": f"Basic {creds}"})
    assert r.status_code == 303


def test_list_rejects_wrong_query_token(client, env):
    r = client.get("/list?token=wrong")
    assert r.status_code == 303


def test_logout_clears_cookie(client, env):
    client.post("/login", data={"password": env["ISO_PASSWORD"]})
    r = client.get("/logout")
    assert r.status_code == 303
    # cookie cleared (set with empty value or expired)
    assert "iso_auth" not in client.cookies or client.cookies.get("iso_auth") == ""


# ─── Multi-password (ISO_PASSWORDS colon-separated list) ───────────────────────

def test_iso_passwords_list_all_accepted(monkeypatch, iso_dir, make_iso):
    """All passwords in ISO_PASSWORDS should authenticate; wrong one rejected."""
    import importlib, secrets, sys, base64
    monkeypatch.setenv("ISO_PASSWORDS", "first-pass:second-pass:third-pass")
    monkeypatch.setenv("ISO_PASSWORD", "")
    monkeypatch.setenv("ISO_COOKIE_SECRET", secrets.token_urlsafe(32))
    monkeypatch.setenv("ISO_DIR", str(iso_dir))
    monkeypatch.setenv("PUBLIC_URL", "https://test.local")
    monkeypatch.setenv("RESEND_API_KEY", "x")
    monkeypatch.setenv("RESEND_FROM", "x@x")
    monkeypatch.setenv("RESEND_TO", "y@y")
    for k in [m for m in list(sys.modules) if m == "app" or m.startswith("app.")]:
        sys.modules.pop(k, None)
    import app
    from fastapi.testclient import TestClient
    c = TestClient(app.app, follow_redirects=False, base_url="https://testserver")

    # All three passwords work via ?token=
    for pw in ("first-pass", "second-pass", "third-pass"):
        r = c.get(f"/list?token={pw}")
        assert r.status_code == 200, f"{pw} should auth via token"

    # All three work via Basic auth
    for pw in ("first-pass", "second-pass", "third-pass"):
        creds = base64.b64encode(f"any:{pw}".encode()).decode()
        r = c.get("/list", headers={"Authorization": f"Basic {creds}"})
        assert r.status_code == 200, f"{pw} should auth via Basic"

    # All three work via /login form
    for pw in ("first-pass", "second-pass", "third-pass"):
        r = c.post("/login", data={"password": pw})
        assert r.status_code == 303, f"{pw} should auth via form"

    # Wrong password rejected via every door. Use a fresh client to avoid
    # the cookie from successful form-logins above letting us through.
    c2 = TestClient(app.app, follow_redirects=False, base_url="https://testserver")
    r = c2.get("/list?token=not-a-password")
    assert r.status_code == 303
    creds = base64.b64encode(b"any:not-a-password").decode()
    r = c2.get("/list", headers={"Authorization": f"Basic {creds}"})
    assert r.status_code == 303
    r = c2.post("/login", data={"password": "not-a-password"})
    assert r.status_code == 401


def test_iso_password_singular_still_works_for_backcompat(monkeypatch, iso_dir):
    """Existing installs with only ISO_PASSWORD set should keep working."""
    import importlib, secrets, sys
    monkeypatch.setenv("ISO_PASSWORD", "single-mode")
    monkeypatch.delenv("ISO_PASSWORDS", raising=False)
    monkeypatch.setenv("ISO_COOKIE_SECRET", secrets.token_urlsafe(32))
    monkeypatch.setenv("ISO_DIR", str(iso_dir))
    monkeypatch.setenv("PUBLIC_URL", "https://test.local")
    monkeypatch.setenv("RESEND_API_KEY", "x")
    monkeypatch.setenv("RESEND_FROM", "x@x")
    monkeypatch.setenv("RESEND_TO", "y@y")
    for k in [m for m in list(sys.modules) if m == "app" or m.startswith("app.")]:
        sys.modules.pop(k, None)
    import app
    from fastapi.testclient import TestClient
    c = TestClient(app.app, follow_redirects=False, base_url="https://testserver")

    r = c.get("/list?token=single-mode")
    assert r.status_code == 200
    r = c.post("/login", data={"password": "single-mode"})
    assert r.status_code == 303
