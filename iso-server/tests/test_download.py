"""Tests for the ISO download endpoint — auth, Range, path traversal."""


def test_download_requires_auth(client, make_iso):
    make_iso("26200.8328")
    r = client.get("/iso/Win11-25H2-Pro-26200.8328-RST-Rufus.iso")
    assert r.status_code == 303
    assert r.headers["location"] == "/login"


def test_download_with_token_works(client, env, make_iso):
    p = make_iso("26200.8328", size_bytes=4096)
    name = p.name
    r = client.get(f"/iso/{name}?token={env['ISO_PASSWORD']}")
    assert r.status_code == 200
    assert len(r.content) == 4096
    assert r.headers["content-type"] == "application/octet-stream"


def test_download_with_basic_auth_works(client, env, make_iso):
    import base64
    p = make_iso("26200.8328", size_bytes=4096)
    creds = base64.b64encode(f"x:{env['ISO_PASSWORD']}".encode()).decode()
    r = client.get(f"/iso/{p.name}", headers={"Authorization": f"Basic {creds}"})
    assert r.status_code == 200
    assert len(r.content) == 4096


def test_download_supports_range(client, env, make_iso):
    p = make_iso("26200.8328", size_bytes=10000)
    r = client.get(
        f"/iso/{p.name}?token={env['ISO_PASSWORD']}",
        headers={"Range": "bytes=100-199"},
    )
    assert r.status_code == 206
    assert len(r.content) == 100
    assert r.headers["content-range"].startswith("bytes 100-199/10000")


def test_download_404_for_missing_file(client, env):
    r = client.get(f"/iso/nope.iso?token={env['ISO_PASSWORD']}")
    assert r.status_code == 404


def test_download_blocks_path_traversal(client, env):
    r = client.get(f"/iso/..%2Fetc%2Fpasswd?token={env['ISO_PASSWORD']}")
    # Either 404 (our guard) or 400 (FastAPI URL parsing) — both acceptable
    assert r.status_code in (400, 404)


def test_download_blocks_subdirectory(client, env):
    r = client.get(f"/iso/sub/file.iso?token={env['ISO_PASSWORD']}")
    assert r.status_code == 404


def test_download_range_suffix(client, env, make_iso):
    """`Range: bytes=-200` means the LAST 200 bytes (RFC 9110 §14.1.2)."""
    p = make_iso("26200.8328", size_bytes=1000)
    r = client.get(
        f"/iso/{p.name}?token={env['ISO_PASSWORD']}",
        headers={"Range": "bytes=-200"},
    )
    assert r.status_code == 206
    assert len(r.content) == 200
    assert r.headers["content-range"] == "bytes 800-999/1000"


def test_download_range_open_ended(client, env, make_iso):
    """`Range: bytes=900-` means from byte 900 to EOF — common resume pattern."""
    p = make_iso("26200.8328", size_bytes=1000)
    r = client.get(
        f"/iso/{p.name}?token={env['ISO_PASSWORD']}",
        headers={"Range": "bytes=900-"},
    )
    assert r.status_code == 206
    assert len(r.content) == 100
    assert r.headers["content-range"] == "bytes 900-999/1000"


def test_download_range_past_eof_clamps(client, env, make_iso):
    """`Range: bytes=0-99999` on a 1000-byte file should clamp to 999, not 416."""
    p = make_iso("26200.8328", size_bytes=1000)
    r = client.get(
        f"/iso/{p.name}?token={env['ISO_PASSWORD']}",
        headers={"Range": "bytes=0-99999"},
    )
    assert r.status_code == 206
    assert len(r.content) == 1000


def test_download_range_unsatisfiable_returns_416(client, env, make_iso):
    """`Range: bytes=2000-3000` on a 1000-byte file is unsatisfiable → 416."""
    p = make_iso("26200.8328", size_bytes=1000)
    r = client.get(
        f"/iso/{p.name}?token={env['ISO_PASSWORD']}",
        headers={"Range": "bytes=2000-3000"},
    )
    assert r.status_code == 416
    assert "content-range" in r.headers
