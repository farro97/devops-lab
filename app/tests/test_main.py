"""Unit tests. These run in CI without a database."""

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health_is_ok():
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_root_reports_version_and_environment():
    body = client.get("/").json()
    assert body["app"] == "devops-lab"
    assert "version" in body
    assert "environment" in body


def test_db_endpoint_returns_503_when_db_not_configured(monkeypatch):
    monkeypatch.delenv("DB_HOST", raising=False)
    resp = client.get("/db")
    assert resp.status_code == 503
    assert "not configured" in resp.json()["detail"]
