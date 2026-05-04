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
