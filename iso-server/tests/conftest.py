"""Shared test fixtures for the iso-server app."""
import os
import secrets
import tempfile
from pathlib import Path

import pytest


@pytest.fixture
def iso_dir(tmp_path: Path) -> Path:
    """A temp directory standing in for /srv/iso."""
    d = tmp_path / "iso"
    d.mkdir()
    return d


@pytest.fixture
def env(iso_dir: Path, monkeypatch) -> dict:
    """Set the env vars the app reads."""
    cfg = {
        "ISO_PASSWORD": "hunter2",
        "ISO_COOKIE_SECRET": secrets.token_urlsafe(32),
        "ISO_DIR": str(iso_dir),
        "PUBLIC_URL": "https://test.local",
        "RESEND_API_KEY": "test-key",
        "RESEND_FROM": "test@test.local",
        "RESEND_TO": "to@test.local",
    }
    for k, v in cfg.items():
        monkeypatch.setenv(k, v)
    return cfg


@pytest.fixture
def client(env):
    """Return a TestClient with a freshly-imported app (env-aware)."""
    # Pop cached app + any submodules so env vars set by `env` fixture are read fresh
    import sys
    for mod in [k for k in list(sys.modules) if k == "app" or k.startswith("app.")]:
        sys.modules.pop(mod, None)
    import app  # noqa: PLC0415
    from fastapi.testclient import TestClient
    return TestClient(app.app, follow_redirects=False, base_url="https://testserver")


@pytest.fixture
def make_iso(iso_dir):
    """Helper to create fake ISO files with given build number and size."""
    def _make(build: str, size_bytes: int = 1024) -> Path:
        p = iso_dir / f"Win11-25H2-Pro-{build}-RST-Rufus.iso"
        p.write_bytes(b"\x00" * size_bytes)
        return p
    return _make
