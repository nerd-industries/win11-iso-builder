"""Tests for the ISO listing page."""


def test_list_empty_directory(client, env):
    client.post("/login", data={"password": env["ISO_PASSWORD"]})
    r = client.get("/list")
    assert r.status_code == 200
    # No <li> entries when no ISOs exist
    assert "<li" not in r.text or "Win11-25H2-Pro" not in r.text


def test_list_shows_isos_newest_first(client, env, make_iso, iso_dir):
    import os, time
    p1 = make_iso("26200.8313")
    time.sleep(0.05)
    p2 = make_iso("26200.8328")
    # Force mtime ordering deterministically
    os.utime(p1, (time.time() - 100, time.time() - 100))
    os.utime(p2, (time.time(), time.time()))

    client.post("/login", data={"password": env["ISO_PASSWORD"]})
    r = client.get("/list")
    assert r.status_code == 200
    # 8328 should appear before 8313 in the rendered HTML
    pos_new = r.text.find("26200.8328")
    pos_old = r.text.find("26200.8313")
    assert 0 <= pos_new < pos_old


def test_list_only_includes_matching_pattern(client, env, iso_dir):
    (iso_dir / "Win11-25H2-Pro-26200.8328-RST-Rufus.iso").write_bytes(b"\x00")
    (iso_dir / "random-other-file.iso").write_bytes(b"\x00")
    (iso_dir / "notes.txt").write_text("hi")

    client.post("/login", data={"password": env["ISO_PASSWORD"]})
    r = client.get("/list")
    assert "26200.8328" in r.text
    assert "random-other-file" not in r.text
    assert "notes.txt" not in r.text
